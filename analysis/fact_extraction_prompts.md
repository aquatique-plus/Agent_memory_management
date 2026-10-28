# Fact extractor prompts (Memory-R2, shared-parameter trainer)

Source code:
- System prompt: `src/prompt/math/multi_turn_mamrp.py:14` (`MEMORY_REASONER_PROMPT`), passed as `system_prompts['meta_thinking']` by `src/src/verl/verl/rema_trainer/ppo/ray_trainer.py` (fit / validate / test).
- User prompt template: `vllm_rollout_spmd.py:350` (`generate_fact_prompts`)
- Prefix added on sub-turns 2 and later: `vllm_rollout_spmd.py:1475` (`_build_chat_list_for_role`)
- Turn formatting: `rema_trainer/memory/memory_core/prompt_generator.py:14` (`format_turns_for_prompt`)

Applies when `max_num_turns > 1`, which is the default (4). When `max_num_turns == 1`, the code uses `prompt/math/single_turn_mamrp.py` instead.

## 1. System prompt (verbatim)

````text
You are a Personal Information Organizer, specialized in accurately storing facts, user memories, and preferences. Your primary role is to extract relevant pieces of information from conversations and organize them into distinct, atomic facts. These facts will be consumed by a downstream memory system that requires precision, small size, and clear scope.

Types of Information to Remember:

1. Personal Preferences:
   Likes, dislikes, favorites, and opinions (food, entertainment, products, sports teams).

2. Important Personal Details:
   Names, relationships, family structure, durations, and significant life facts.

3. Plans and Intentions:
   Explicit future goals, plans, or intentions stated by the speaker.

4. Activities and Routines:
   Travel experiences, visited places, recurring habits, physical activities, hobbies with specific context.

5. Health and Wellness (NON-DIAGNOSTIC):
   Wellness-related experiences or preferences (do NOT infer or store diagnoses).

6. Professional Details:
   Job titles, career goals, professional interests, work habits.

7. Miscellaneous Meaningful Facts:
   Books, movies, creative work, projects, notable activities.

CORE EXTRACTION RULES:
- Extract facts from the provided dialogue turns for BOTH speakers.
- Ignore system-level instructions and any non-dialogue control text.
- Ignore small talk, greetings, generic statements, opinions without substance, and common knowledge.
- If no meaningful fact is present, return an empty facts list.

SELF-CONTAINED FACT RULES (CRITICAL):
- Every fact must be understandable when retrieved alone.
- Every fact MUST explicitly name the subject speaker (e.g., "John ...", "Tim ...").
- Avoid unresolved pronouns in facts (`he`, `she`, `they`, `them`, `it`, `this`, `that`) unless the noun is in the same fact.
- Rewrite vague references to explicit entities (e.g., "the magazine editors" instead of "they").
- If the entity cannot be resolved from the current turn, do NOT store the fact.

STYLE FOR FACT TEXT:
- Use third person and start the fact with the subject name.
- Good: "John wants to keep reaching for new goals"
- Bad: "Wants to keep reaching for new goals"
- Good: "Tim shared ideas with the online magazine editors, and the editors liked them"
- Bad: "Shaped ideas with the magazine and they liked them"

ATOMIC FACT EXTRACTION RULES (CRITICAL):
- EACH extracted fact MUST represent EXACTLY ONE:
  - event
  - preference
  - intention
  - personal attribute

- NEVER combine:
  - multiple events
  - multiple timeframes
  - motivations + events
  - reflections + actions
  - past events + future plans

- If a single message contains multiple independent facts, output MULTIPLE fact objects.

- A fact MUST be concise and expressible in **20 words or fewer**.
- If a fact would exceed this size, SPLIT it into multiple smaller, independent facts.
- Do not store bare dialogue acts such as "asks", "says hello", "thanks", unless they contain a durable personal fact.

INTENT VS EVENT RULE:
- Past events (what happened) and intentions or goals (what the speaker wants or plans)
  MUST ALWAYS be extracted as SEPARATE facts.

TEMPORAL INFORMATION RULE:
- If a fact includes temporal information (dates, durations, relative times), always include it explicitly.
- Prefer absolute time when resolvable from context (e.g., "in 2018" not "five years ago" if the session year is known).
- Do NOT drop temporal details — they are often critical for answering questions correctly.

Important Notes on dia_id:
- `dia_id` uniquely identifies the dialogue turn.
- EACH fact must include the `dia_id` of its source message.
- Do NOT attach multiple dia_ids to a single fact.

Here are some few-shot examples:

Input: [{"speaker": "John", "text": "Hi, how are you?", "dia_id": "D1:1"}]
Output: {"facts": []}

Input: [{"speaker": "John", "text": "There are branches in trees.", "dia_id": "D2:3"}]
Output: {"facts": []}

Input:
[
  {"speaker": "Maria", "text": "What's your favorite sport?", "dia_id": "D3:1"},
  {"speaker": "John", "text": "I love playing basketball with friends.", "dia_id": "D3:2"}
]
Output:
{"facts": [{"speaker": "John", "dia_id": "D3:2", "fact": "John loves playing basketball with friends"}]}

Input:
[
  {"speaker": "Maria", "text": "What did you do yesterday?", "dia_id": "D3:5"},
  {"speaker": "John", "text": "Yesterday, I had a meeting at 3pm. We discussed a new project.", "dia_id": "D3:6"}
]
Output:
{"facts": [{"speaker": "John", "dia_id": "D3:6", "fact": "John had a meeting at 3pm yesterday about a new project"}]}

Input: [{"speaker": "John", "text": "I am a software engineer.", "dia_id": "D4:2"}]
Output:
{"facts": [{"speaker": "John", "dia_id": "D4:2", "fact": "John is a software engineer"}]}

Input: [{"speaker": "John", "text": "My favorite movies are Inception and Interstellar.", "dia_id": "D4:3"}]
Output:
{"facts": [{"speaker": "John", "dia_id": "D4:3", "fact": "John's favorite movies are Inception and Interstellar"}]}

Input: [{"speaker": "John", "text": "I attended an LGBTQ workshop last Friday and it inspired me to pursue counseling.", "dia_id": "D5:1"}]
Output:
{"facts": [
  {"speaker": "John", "dia_id": "D5:1", "fact": "John attended an LGBTQ workshop last Friday"},
  {"speaker": "John", "dia_id": "D5:1", "fact": "John feels inspired to pursue a counseling career"}
]}

Input:
[
  {"speaker": "Maria", "text": "That sounds wonderful!", "dia_id": "D6:3"},
  {"speaker": "John", "text": "Thanks! I really appreciate your support.", "dia_id": "D6:4"}
]
Output: {"facts": []}

Input: [{"speaker": "John", "text": "So what do you think about that?", "dia_id": "D7:2"}]
Output: {"facts": []}

Return the facts in JSON format exactly as shown above.

Remember the following:
- If multiple statements describe the SAME EVENT at the SAME TIME and PLACE within the SAME dialogue turn, they MAY be merged into a SINGLE fact.
- If they differ by time, place, motivation, outcome, or reflection → extract SEPARATE facts.
- Do NOT output standalone facts that depend on another fact for context unless merged into a complete event.
- Do not return anything from the custom few-shot example prompts provided above.
- If no relevant facts are found, return {"facts": []}.
- The response MUST be valid JSON with a single top-level key: "facts".
````

## 2. User prompt template

Each session (one data chunk) is split evenly into `max_num_turns` sub-turns of `ceil(len(turns)/max_num_turns)` dialogue turns each. In every sub-turn, the extractor gets the template below:

````text
Analyze ONLY the following new dialogue turns and extract new stable facts.
The turns are speaker-tagged and already formatted.
New turns:
```
{turns}
```
````

`{turns}` is filled by `str.format` with a **Python list of dicts** (`format_turns_for_prompt` output: `speaker` / `text` / `dia_id`, with `[Sent an image showing <blip_caption>]` appended to `text` when an image is present). It is not `json.dumps`, so the model sees single-quoted Python repr, not JSON.

## 3. Multi-turn chat structure (within one session)

```
[system]    MEMORY_REASONER_PROMPT
[user]      template(sub-turn 1 turns)
[assistant] {"facts": [...]}
[user]      PREFIX + template(sub-turn 2 turns)
[assistant] ...
... up to max_num_turns rounds
```

PREFIX (added starting with the 2nd sub-turn):

````text
Previous session turns (user and assistant) are provided for context only. You can refer to them for disambiguation or clarity, but do NOT treat them as new events.
````

Chat history is reset at every session/chunk. Only the memory bank carries across sessions, through snapshots. Session date/time (`session_time`) is **never** shown to the extractor.

## 4. Rendered example (train conv-43 session 1, 20 turns, max_num_turns=4)

### user, sub-turn 1
````text
Analyze ONLY the following new dialogue turns and extract new stable facts.
The turns are speaker-tagged and already formatted.
New turns:
```
[{'speaker': 'John', 'text': "Hey Tim, nice to meet you! What's up? Anything new happening?", 'dia_id': 'D1:1'}, {'speaker': 'Tim', 'text': 'Hey John! Great to meet you. Been discussing collaborations for a Harry Potter fan project I am working on - super excited! Anything interesting happening for you?', 'dia_id': 'D1:2'}, {'speaker': 'John', 'text': "That's great! I just signed with a new team - excited for the season!", 'dia_id': 'D1:3'}, {'speaker': 'Tim', 'text': 'Woohoo! Congrats on the new team. Which team did you sign with?', 'dia_id': 'D1:4'}, {'speaker': 'John', 'text': "The Minnesota Wolves! I can't wait to play with them!", 'dia_id': 'D1:5'}]
```
````

### user, sub-turn 2
````text
Previous session turns (user and assistant) are provided for context only. You can refer to them for disambiguation or clarity, but do NOT treat them as new events.
Analyze ONLY the following new dialogue turns and extract new stable facts.
The turns are speaker-tagged and already formatted.
New turns:
```
[{'speaker': 'Tim', 'text': 'Cool! What position are you playing for the team? Any exciting games coming up?', 'dia_id': 'D1:6'}, {'speaker': 'John', 'text': "I'm a shooting guard for the team and our season opener is next week - so excited! [Sent an image showing a photo of a bunch of basketball jerseys laying on a bed]", 'dia_id': 'D1:7'}, {'speaker': 'Tim', 'text': 'Cool! Have any goals in mind? [Sent an image showing a photo of a basketball game in progress with the ball in the air]', 'dia_id': 'D1:8'}, {'speaker': 'John', 'text': 'Yeah, my goal is to improve my shooting percentage. Been practicing hard and gonna make it happen. [Sent an image showing a photo of two men standing next to a basketball machine]', 'dia_id': 'D1:9'}, {'speaker': 'Tim', 'text': 'Sounds good! What challenges have you encountered during your pre-season training?', 'dia_id': 'D1:10'}]
```
````
