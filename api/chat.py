import os
import json
import random
import threading
import requests
from flask import Flask, Response, request, send_from_directory
from flask_cors import CORS

app = Flask(__name__, static_folder='.')
CORS(app)

# ===== API KEYS =====
# URGENT: Environment variable orqali o'rnating!
# Vercel: Settings → Environment Variables → OPENROUTER_KEYS, GROQ_KEYS
# Local: export OPENROUTER_KEYS="sk-or-v1-xxx,sk-or-v1-yyy"
OPENROUTER_KEYS = [k for k in os.environ.get('OPENROUTER_KEYS', '').split(',') if k]
GROQ_KEYS = [k for k in os.environ.get('GROQ_KEYS', '').split(',') if k]

if not OPENROUTER_KEYS:
    print("WARNING: OPENROUTER_KEYS not set, will fall back if needed")
if not GROQ_KEYS:
    print("WARNING: GROQ_KEYS not set, will fall back if needed")

OPENROUTER_URL = 'https://openrouter.ai/api/v1/chat/completions'
GROQ_URL = 'https://api.groq.com/openai/v1/chat/completions'

# ===== AGENT CONFIG =====
AGENTS = {
    'orchestrator': {'provider': 'groq', 'model': 'gemma2-9b-it'},
    'search':       {'provider': 'groq', 'model': 'gemma2-9b-it'},
    'code':         {'provider': 'groq', 'model': 'gemma2-9b-it'},
    'analysis':     {'provider': 'groq', 'model': 'gemma2-9b-it'},
}

_key_index = 0
_groq_index = 0

def next_key(provider):
    global _key_index, _groq_index
    if provider == 'openrouter':
        if not OPENROUTER_KEYS:
            raise Exception("No OpenRouter keys available")
        k = OPENROUTER_KEYS[_key_index % len(OPENROUTER_KEYS)]
        _key_index += 1
        return k
    else:
        if not GROQ_KEYS:
            raise Exception("No Groq keys available")
        k = GROQ_KEYS[_groq_index % len(GROQ_KEYS)]
        _groq_index += 1
        return k

def api_call(messages, agent_key, stream=False, max_tokens=None):
    agent = AGENTS[agent_key]
    url = OPENROUTER_URL if agent['provider'] == 'openrouter' else GROQ_URL
    api_key = next_key(agent['provider'])

    headers = {
        'Content-Type': 'application/json',
        'Authorization': f'Bearer {api_key}',
    }
    if agent['provider'] == 'openrouter':
        headers['HTTP-Referer'] = 'https://ai-chat.vercel.app'

    body = {
        'model': agent['model'],
        'messages': messages,
        'stream': stream,
        'temperature': 0.7,
    }
    if max_tokens:
        body['max_tokens'] = max_tokens

    try:
        resp = requests.post(url, headers=headers, json=body, stream=stream, timeout=60)
        resp.raise_for_status()

        if stream:
            result = ''
            for line in resp.iter_lines(decode_unicode=True):
                if not line or not line.startswith('data: '):
                    continue
                data = line[6:].strip()
                if data == '[DONE]' or not data:
                    continue
                try:
                    parsed = json.loads(data)
                    delta = parsed.get('choices', [{}])[0].get('delta', {}).get('content', '')
                    result += delta
                except json.JSONDecodeError:
                    pass
            return result
        else:
            data = resp.json()
            return data.get('choices', [{}])[0].get('message', {}).get('content', '')
    except requests.exceptions.RequestException as e:
        raise Exception(f'Agent {agent_key} error: {e}')

# ===== AGENT PROMPTS =====
ORCHESTRATOR_SYSTEM = '''You are a task orchestrator. Analyze the user's query and create a plan.
Return ONLY a JSON array of steps. Each step has: "agent" (search/code/analysis), "task" (description).
Rules:
- If query needs research/latest info -> use "search" agent
- If query needs code/examples -> use "code" agent
- "analysis" agent is always used last to synthesize
- Max 4 steps total
Example: [{"agent":"search","task":"Search for X"},{"agent":"analysis","task":"Analyze findings"}]
Return ONLY valid JSON, no other text.'''

SEARCH_SYSTEM = '''You are a research agent. Search your knowledge for relevant, up-to-date information.
Return:
1. Key findings with details
2. Sources/citations (title, domain, relevance)
Format as JSON: {"findings":"...","sources":[{"title":"...","domain":"..."}]}
Be thorough and specific. Return ONLY valid JSON.'''

CODE_SYSTEM = '''You are a code agent. Write clean, working code with explanations.
Include:
1. Approach explanation
2. Full code
3. Usage example
Return as JSON: {"approach":"...","code":"...","usage":"..."}
Return ONLY valid JSON.'''

ANALYSIS_SYSTEM = '''You are a synthesis agent. Combine all agent outputs into one clear, comprehensive answer.
Use markdown formatting. Include code blocks, tables, lists where appropriate.
Cite sources at the end. Be concise but thorough.'''

def call_agent(agent_key, system, user_msg, stream=False, max_tokens=None):
    messages = [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user_msg},
    ]
    return api_call(messages, agent_key, stream=stream, max_tokens=max_tokens)

def execute_agent(agent_type, task):
    system = {
        'search': SEARCH_SYSTEM,
        'code': CODE_SYSTEM,
        'analysis': ANALYSIS_SYSTEM,
    }.get(agent_type, ANALYSIS_SYSTEM)

    result = call_agent(agent_type, system, task, stream=False, max_tokens=2000)

    sources = []
    if agent_type == 'search':
        try:
            parsed = json.loads(result)
            sources = parsed.get('sources', [])
        except json.JSONDecodeError:
            pass

    return result, sources

# ===== SSE GENERATOR =====
def generate_sse(user_query):
    # Step 1: Orchestrator
    yield f'event: thinking\ndata: {json.dumps({"step": 0, "label": "Planning task breakdown...", "total": 5})}\n\n'
    try:
        raw_plan = call_agent('orchestrator', ORCHESTRATOR_SYSTEM, user_query, max_tokens=500)
        raw_plan = raw_plan.strip().removeprefix('```json').removesuffix('```').strip()
        plan = json.loads(raw_plan)
        steps = plan if isinstance(plan, list) else [{'agent': 'analysis', 'task': user_query}]
    except Exception as e:
        steps = [{'agent': 'analysis', 'task': user_query}]

    plan_str = ' → '.join(s['agent'] for s in steps)
    yield f'event: thinking\ndata: {json.dumps({"step": 0, "label": f"Plan: {plan_str}", "total": len(steps) + 1, "done": True})}\n\n'

    # Step 2: Execute agents
    agent_tasks = [s for s in steps if s['agent'] != 'analysis']
    results = []
    all_sources = []

    threads = []
    lock = threading.Lock()

    def run_agent(s, i):
        nonlocal results
        yield f'event: thinking\ndata: {json.dumps({"step": i + 1, "label": f"{s["agent"].capitalize()}: {s["task"][:60]}", "total": len(steps) + 1})}\n\n'
        result, sources = execute_agent(s['agent'], s['task'])
        with lock:
            results.append({'agent': s['agent'], 'result': result})
            all_sources.extend(sources)
            yield f'event: agent_result\ndata: {json.dumps({"agent": s["agent"], "result": result})}\n\n'
            if sources:
                yield f'event: sources\ndata: {json.dumps(sources)}\n\n'

    # Threaded execution
    output_queue = []
    agent_outputs = [None] * len(agent_tasks)

    def thread_func(idx, step):
        out = []
        for event in run_agent(step, idx):
            out.append(event)
        agent_outputs[idx] = out

    threads = []
    for i, step in enumerate(agent_tasks):
        t = threading.Thread(target=thread_func, args=(i, step))
        t.start()
        threads.append(t)

    for t in threads:
        t.join()

    for out in agent_outputs:
        if out:
            output_queue.extend(out)

    for event in output_queue:
        yield event

    # Step 3: Build context for synthesis
    context_parts = [f'User query: {user_query}']
    for r in results:
        context_parts.append(f'=== {r["agent"].upper()} OUTPUT ===\n{r["result"]}')
    full_context = '\n\n'.join(context_parts)

    # Step 4: Stream synthesis
    yield f'event: thinking\ndata: {json.dumps({"step": len(steps), "label": "Synthesizing final response...", "total": len(steps) + 1})}\n\n'
    yield f'event: agent_stream_start\ndata: {json.dumps({"agent": "analysis"})}\n\n'

    agent = AGENTS['analysis']
    url = OPENROUTER_URL if agent['provider'] == 'openrouter' else GROQ_URL
    api_key = next_key(agent['provider'])

    headers = {
        'Content-Type': 'application/json',
        'Authorization': f'Bearer {api_key}',
    }
    if agent['provider'] == 'openrouter':
        headers['HTTP-Referer'] = 'https://ai-chat.vercel.app'

    body = {
        'model': agent['model'],
        'messages': [
            {'role': 'system', 'content': ANALYSIS_SYSTEM},
            {'role': 'user', 'content': full_context},
        ],
        'stream': True,
        'temperature': 0.7,
        'max_tokens': 4096,
    }

    try:
        resp = requests.post(url, headers=headers, json=body, stream=True, timeout=120)
        resp.raise_for_status()
        for line in resp.iter_lines(decode_unicode=True):
            if not line or not line.startswith('data: '):
                continue
            data = line[6:].strip()
            if data == '[DONE]' or not data:
                continue
            try:
                parsed = json.loads(data)
                delta = parsed.get('choices', [{}])[0].get('delta', {}).get('content', '')
                if delta:
                    yield f'event: token\ndata: {json.dumps(delta)}\n\n'
            except json.JSONDecodeError:
                pass
    except Exception as e:
        yield f'event: error\ndata: {json.dumps(str(e))}\n\n'

    yield f'event: thinking\ndata: {json.dumps({"step": len(steps), "label": "Done", "total": len(steps) + 1, "done": True})}\n\n'
    yield 'event: done\ndata:\n\n'


# ===== ROUTES =====
@app.route('/api/chat', methods=['POST', 'OPTIONS'])
def chat():
    if request.method == 'OPTIONS':
        return '', 204

    data = request.get_json()
    messages = data.get('messages', [])
    user_msg = messages[-1]['content'] if messages else ''

    return Response(
        generate_sse(user_msg),
        mimetype='text/event-stream',
        headers={
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
            'X-Accel-Buffering': 'no',
        }
    )

@app.route('/', defaults={'path': ''})
@app.route('/<path:path>')
def static_files(path):
    if not path:
        return send_from_directory('.', 'index.html')
    try:
        return send_from_directory('.', path)
    except:
        return send_from_directory('.', 'index.html')

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 3001))
    print(f'Starting Multi-Agent AI Chat on http://localhost:{port}')
    app.run(host='0.0.0.0', port=port, debug=True)
