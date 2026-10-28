"""Time-share the policy's GPUs with the answer-agent vLLM servers.

Training and evaluation alternate between policy phases (rollout, log-prob, update, checkpoint I/O)
and reward phases (the answer agent answers QA over the written memory). Instead of reserving
separate GPUs for the answer agent, the servers are started on the policy's GPUs right before a
reward call and stopped before the next policy GPU call:

  * reward_fn / val_reward_fn are wrapped to bring the servers up (no-op if already up), so the
    inner and terminal reward calls of one step share a single server start;
  * every policy worker-group method that touches the GPU is wrapped to shut the servers down first.

While the servers run, the policy holds almost no GPU memory: vLLM sleeps after each rollout
(weights to CPU, KV cache freed) and the actor/ref FSDP params and optimizer must be configured
with param_offload / optimizer_offload. judge_llm.py builds its clients from JUDGE_BASE_URLS at
import time, so the servers always come back on the same localhost ports.

Enabled by ANSWER_AGENT_TIMESHARE=1; configured through the ANSWER_AGENT_* variables read in
install_from_env().
"""

import atexit
import os
import signal
import subprocess
import time
import urllib.request

# Worker-group methods that run on the policy GPUs; the answer agent must be down before any of them.
_POLICY_GPU_METHODS = (
    'generate_sequences',
    'multi_turn_generate_sequences',
    'compute_log_prob',
    'compute_ref_log_prob',
    'compute_values',
    'update_actor',
    'update_critic',
    'save_checkpoint',
    'load_checkpoint',
)

_GB = 1024**3


class TimeSharedAnswerAgent:

    def __init__(self, launch_cmd, base_urls, gpus, policy_wgs, log_path,
                 startup_timeout_s, max_gpu_mem_util, headroom_gb):
        self.launch_cmd = launch_cmd
        self.base_urls = base_urls
        self.gpus = gpus
        self.policy_wgs = policy_wgs
        self.log_path = log_path
        self.startup_timeout_s = startup_timeout_s
        self.max_gpu_mem_util = max_gpu_mem_util
        self.headroom_gb = headroom_gb
        self.proc = None
        self.free_before_start = None
        self.num_starts = 0
        self.total_start_s = 0.0
        atexit.register(self.stop)

    def _policy_free_bytes(self):
        """Min free bytes over the policy ranks, after each rank drops PyTorch's cached blocks."""
        free = []
        for wg in self.policy_wgs:
            free.extend(wg.release_gpu_memory())
        return min(free), max(free)

    def start(self):
        if self.proc is not None:
            if self.proc.poll() is None:
                return
            raise RuntimeError(f'[answer-agent] servers exited unexpectedly (rc={self.proc.returncode}); '
                               f'see {self.log_path}')
        t0 = time.time()
        free_min, _ = self._policy_free_bytes()
        self.free_before_start = free_min
        total = _total_gpu_bytes()
        # vLLM refuses to start unless gpu_memory_utilization * total fits in the current free memory.
        util = min(self.max_gpu_mem_util, (free_min - self.headroom_gb * _GB) / total)
        if util < 0.5:
            raise RuntimeError(f'[answer-agent] only {free_min / _GB:.1f}GB free per GPU after policy offload; '
                               f'check actor/ref param_offload and optimizer_offload')
        env = dict(os.environ, CUDA_VISIBLE_DEVICES=self.gpus, VLLM_GPU_MEM_UTIL=f'{util:.3f}')
        print(f'[answer-agent] starting on GPUs {self.gpus} (free/GPU {free_min / _GB:.1f}GB, '
              f'gpu_memory_utilization {util:.3f})', flush=True)
        log = open(self.log_path, 'a')
        # New session so stop() can signal the whole tree (bash -> apptainer -> vLLM workers).
        self.proc = subprocess.Popen(self.launch_cmd, env=env, stdout=log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
        log.close()
        for url in self.base_urls:
            while not _healthy(url):
                if self.proc.poll() is not None:
                    raise RuntimeError(f'[answer-agent] servers exited during startup '
                                       f'(rc={self.proc.returncode}); see {self.log_path}')
                if time.time() - t0 > self.startup_timeout_s:
                    self.stop()
                    raise RuntimeError(f'[answer-agent] {url} not healthy after {self.startup_timeout_s}s; '
                                       f'see {self.log_path}')
                time.sleep(5)
        elapsed = time.time() - t0
        self.num_starts += 1
        self.total_start_s += elapsed
        print(f'[answer-agent] ready in {elapsed:.0f}s (start #{self.num_starts})', flush=True)

    def stop(self):
        if self.proc is None:
            return
        t0 = time.time()
        if self.proc.poll() is None:
            pgid = os.getpgid(self.proc.pid)
            os.killpg(pgid, signal.SIGTERM)
            try:
                self.proc.wait(timeout=120)
            except subprocess.TimeoutExpired:
                os.killpg(pgid, signal.SIGKILL)
                self.proc.wait()
            # The launcher can exit before its vLLM children; sweep the rest of the group.
            try:
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.proc = None
        # Wait until the servers' memory is actually back before the policy wakes vLLM up again.
        while True:
            free_min, _ = self._policy_free_bytes()
            if free_min >= self.free_before_start - _GB:
                break
            if time.time() - t0 > 300:
                raise RuntimeError(f'[answer-agent] GPU memory not released after stop '
                                   f'({free_min / _GB:.1f}GB free per GPU)')
            time.sleep(2)
        print(f'[answer-agent] stopped in {time.time() - t0:.0f}s', flush=True)


def _healthy(base_url):
    try:
        with urllib.request.urlopen(f'{base_url}/models', timeout=5) as resp:
            return resp.status == 200
    except Exception:
        return False


def _total_gpu_bytes():
    out = subprocess.run(['nvidia-smi', '--query-gpu=memory.total', '--format=csv,noheader,nounits'],
                         capture_output=True, text=True, check=True).stdout
    return min(int(x) for x in out.split()) * 1024**2


def _wrap_before(fn, hook):

    def wrapped(*args, **kwargs):
        hook()
        return fn(*args, **kwargs)

    return wrapped


def install_from_env(trainer):
    """Attach a TimeSharedAnswerAgent to an initialized RayPPOTrainer if ANSWER_AGENT_TIMESHARE=1."""
    if os.environ.get('ANSWER_AGENT_TIMESHARE', '0') != '1':
        return None
    policy_wgs = [trainer.actor_rollout_wg]
    if getattr(trainer, 'use_reference_policy', False) and trainer.ref_policy_wg is not trainer.actor_rollout_wg:
        policy_wgs.append(trainer.ref_policy_wg)
    agent = TimeSharedAnswerAgent(
        launch_cmd=['bash', os.environ['ANSWER_AGENT_LAUNCH_SCRIPT']],
        base_urls=[u.strip() for u in os.environ['JUDGE_BASE_URLS'].split(',') if u.strip()],
        gpus=os.environ['ANSWER_AGENT_GPUS'],
        policy_wgs=policy_wgs,
        log_path=os.environ['ANSWER_AGENT_LOG'],
        startup_timeout_s=int(os.environ.get('ANSWER_AGENT_STARTUP_TIMEOUT', '1800')),
        max_gpu_mem_util=float(os.environ.get('ANSWER_AGENT_MAX_GPU_MEM_UTIL', '0.85')),
        headroom_gb=float(os.environ.get('ANSWER_AGENT_HEADROOM_GB', '2')),
    )
    if trainer.reward_fn is not None:
        trainer.reward_fn = _wrap_before(trainer.reward_fn, agent.start)
    if trainer.val_reward_fn is not None:
        trainer.val_reward_fn = _wrap_before(trainer.val_reward_fn, agent.start)
    wgs = list(policy_wgs)
    if getattr(trainer, 'use_critic', False):
        wgs.append(trainer.critic_wg)
    for wg in wgs:
        for name in _POLICY_GPU_METHODS:
            if hasattr(wg, name):
                setattr(wg, name, _wrap_before(getattr(wg, name), agent.stop))
    trainer.answer_agent = agent
    print(f'[answer-agent] time-sharing GPUs {agent.gpus} with the policy; servers at {agent.base_urls}', flush=True)
    return agent
