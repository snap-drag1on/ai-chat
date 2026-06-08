require 'webrick'
require 'net/http'
require 'json'
require 'uri'
require 'thread'

# ===== API KEYS =====
# Environment variable orqali o'rnating: export OPENROUTER_KEYS="key1,key2" GROQ_KEYS="key1,key2"
OPENROUTER_KEYS = (ENV['OPENROUTER_KEYS'] || '').split(',').map(&:strip).reject(&:empty?)
GROQ_KEYS = (ENV['GROQ_KEYS'] || '').split(',').map(&:strip).reject(&:empty?)

if OPENROUTER_KEYS.empty?
  $stderr.puts "ERROR: OPENROUTER_KEYS environment variable is not set!"
  exit 1
end
if GROQ_KEYS.empty?
  $stderr.puts "ERROR: GROQ_KEYS environment variable is not set!"
  exit 1
end

OPENROUTER_URL = 'https://openrouter.ai/api/v1/chat/completions'
GROQ_URL = 'https://api.groq.com/openai/v1/chat/completions'

PORT = ENV.fetch('PORT', 3001).to_i
$key_index = 0
$groq_key_index = 0
$key_mutex = Mutex.new

# ===== AGENT CONFIG =====
AGENTS = {
  orchestrator: { provider: :groq,      model: 'llama-3.3-70b-versatile' },
  search:       { provider: :groq,      model: 'llama-3.3-70b-versatile' },
  code:         { provider: :groq,      model: 'llama-3.3-70b-versatile' },
  analysis:     { provider: :groq,      model: 'llama-3.3-70b-versatile' },
}

# ===== HELPERS =====
def next_openrouter_key
  $key_mutex.synchronize do
    key = OPENROUTER_KEYS[$key_index % OPENROUTER_KEYS.length]
    $key_index += 1
    key
  end
end

def next_groq_key
  $key_mutex.synchronize do
    key = GROQ_KEYS[$groq_key_index % GROQ_KEYS.length]
    $groq_key_index += 1
    key
  end
end

def api_call(messages, agent_key, stream: false, max_tokens: nil)
  agent = AGENTS[agent_key] or raise "Unknown agent: #{agent_key}"

  # Try providers in order: configured → fallback
  providers_to_try = [
    { url: agent[:provider] == :openrouter ? OPENROUTER_URL : GROQ_URL,
      key: agent[:provider] == :openrouter ? next_openrouter_key : next_groq_key,
      name: agent[:provider] },
    { url: agent[:provider] == :openrouter ? GROQ_URL : OPENROUTER_URL,
      key: agent[:provider] == :openrouter ? next_groq_key : next_openrouter_key,
      name: agent[:provider] == :openrouter ? :groq : :openrouter },
  ]

  last_error = nil
  providers_to_try.each do |provider|
    begin
      uri = URI(provider[:url])
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 60
      http.open_timeout = 15

      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req['Authorization'] = "Bearer #{provider[:key]}"
      req['HTTP-Referer'] = 'http://localhost:3001' if provider[:name] == :openrouter

      body = {
        model: agent[:model],
        messages: messages,
        stream: stream,
        temperature: 0.7,
      }
      body[:max_tokens] = max_tokens if max_tokens
      req.body = body.to_json

      if stream
        result = +''
        http.request(req) do |response|
          unless response.code.to_i == 200
            error_body = response.body rescue 'unknown'
            raise "Agent #{agent_key} #{provider[:name]} error #{response.code}: #{error_body}"
          end
          response.read_body do |chunk|
            chunk.each_line do |line|
              next unless line.start_with?('data: ')
              data = line[6..].strip
              next if data == '[DONE]' || data.empty?
              begin
                parsed = JSON.parse(data)
                delta = parsed.dig('choices', 0, 'delta', 'content') || ''
                result << delta
              rescue JSON::ParserError
              end
            end
          end
        end
        return result
      else
        http_res = http.request(req)
        unless http_res.code.to_i == 200
          error_body = http_res.body rescue 'unknown'
          raise "Agent #{agent_key} #{provider[:name]} error #{http_res.code}: #{error_body}"
        end
        parsed = JSON.parse(http_res.body)
        return parsed.dig('choices', 0, 'message', 'content') || ''
      end
    rescue => e
      last_error = e
      $stderr.puts "API fallback: #{provider[:name]} failed for #{agent_key}: #{e.message}"
    end
  end

  raise last_error || "All providers failed for #{agent_key}"
end

def call_agent(agent_key, system_prompt, user_message, stream: false, max_tokens: nil)
  messages = [
    { role: 'system', content: system_prompt },
    { role: 'user', content: user_message }
  ]
  api_call(messages, agent_key, stream: stream, max_tokens: max_tokens)
end

# ===== ORCHESTRATOR =====
def orchestrator_plan(user_query)
  system_prompt = <<~PROMPT
    You are a task orchestrator. Analyze the user's query and create a plan.
    Return ONLY a JSON array of steps. Each step has: "agent" (search/code/analysis), "task" (description).
    Rules:
    - If query needs research/latest info → use "search" agent
    - If query needs code/examples → use "code" agent
    - "analysis" agent is always used last to synthesize
    - Max 4 steps total
    Example: [{"agent":"search","task":"Search for X"},{"agent":"analysis","task":"Analyze findings"}]
  PROMPT
  raw = call_agent(:orchestrator, system_prompt, user_query, max_tokens: 500)
  raw = raw.strip
  raw = raw.gsub(/^```json\s*|\s*```$/, '')
  JSON.parse(raw)
rescue => e
  $stderr.puts "Orchestrator parse error: #{e.message}, raw: #{raw}"
  [{ 'agent' => 'analysis', 'task' => "Answer: #{user_query}" }]
end

# ===== AGENT PROMPTS =====
SEARCH_SYSTEM = <<~PROMPT
  You are a research agent. Search your knowledge for relevant, up-to-date information.
  Return:
  1. Key findings with details
  2. Sources/citations (title, domain, relevance)
  Format as JSON: {"findings":"...","sources":[{"title":"...","domain":"..."}]}
  Be thorough and specific.
PROMPT

CODE_SYSTEM = <<~PROMPT
  You are a code agent. Write clean, working code with explanations.
  Include:
  1. Approach explanation
  2. Full code
  3. Usage example
  Return as JSON: {"approach":"...","code":"...","usage":"..."}
PROMPT

ANALYSIS_SYSTEM = <<~PROMPT
  You are a synthesis agent. Combine all agent outputs into one clear, comprehensive answer.
  Use markdown formatting. Include code blocks, tables, lists where appropriate.
  Cite sources at the end.
  Be concise but thorough.
PROMPT

# ===== AGENT EXECUTION =====
def execute_agent(agent_type, task, res, step_index, total_steps)
  write_sse(res, 'thinking', { step: step_index, label: "#{agent_type.capitalize}: #{truncate(task, 60)}", total: total_steps }.to_json)

  system_prompt = case agent_type
  when 'search' then SEARCH_SYSTEM
  when 'code' then CODE_SYSTEM
  when 'analysis' then ANALYSIS_SYSTEM
  else ANALYSIS_SYSTEM
  end

  result = call_agent(agent_type.to_sym, system_prompt, task, stream: false, max_tokens: 2000)

  # If search, extract and send sources
  if agent_type == 'search'
    begin
      parsed = JSON.parse(result)
      sources = parsed['sources'] || []
      write_sse(res, 'sources', sources.to_json) unless sources.empty?
    rescue
    end
  end

  write_sse(res, 'agent_result', { agent: agent_type, result: result }.to_json)
  result
rescue => e
  write_sse(res, 'agent_result', { agent: agent_type, result: "Error: #{e.message}", error: true }.to_json)
  "Error in #{agent_type}: #{e.message}"
end

# ===== SSE HELPERS =====
def write_sse(res, event, data)
  res.body << "event: #{event}\ndata: #{data}\n\n"
rescue => e
  $stderr.puts "SSE write error: #{e.message}"
end

def truncate(str, len)
  str.length > len ? str[0...len] + '...' : str
end

# ===== MAIN CHAT HANDLER =====
def handle_chat(req, res)
  body = JSON.parse(req.body)
  messages = body['messages']
  user_msg = messages.last['content']

  res.status = 200
  res['Content-Type'] = 'text/event-stream'
  res['Cache-Control'] = 'no-cache'
  res['Connection'] = 'keep-alive'
  res['Access-Control-Allow-Origin'] = '*'
  res['Access-Control-Allow-Methods'] = 'POST, OPTIONS'
  res['Access-Control-Allow-Headers'] = 'Content-Type'

  # Step 1: Orchestrator plans
  write_sse(res, 'thinking', { step: 0, label: "Planning task breakdown...", total: 5 }.to_json)
  plan = orchestrator_plan(user_msg)
  steps = plan.is_a?(Array) ? plan : [{ 'agent' => 'analysis', 'task' => user_msg }]
  write_sse(res, 'thinking', { step: 0, label: "Plan: #{steps.map{|s| s['agent']}.join(' → ')}", total: steps.length + 1, done: true }.to_json)

  # Step 2: Execute non-analysis agents in parallel
  agent_tasks = steps.select { |s| s['agent'] != 'analysis' }

  threads = []
  agent_tasks.each_with_index do |step, i|
    threads << Thread.new do
      result = execute_agent(step['agent'], step['task'], res, i + 1, steps.length + 1)
      { agent: step['agent'], result: result }
    end
  end

  agent_results = threads.map(&:value)

  # Step 3: Build context
  context_parts = ["User query: #{user_msg}"]
  agent_results.each do |r|
    context_parts << "=== #{r[:agent].upcase} OUTPUT ===\n#{r[:result]}"
  end
  full_context = context_parts.join("\n\n")

  # Step 4: Final synthesis (streamed)
  write_sse(res, 'thinking', { step: steps.length, label: "Synthesizing final response...", total: steps.length + 1 }.to_json)
  write_sse(res, 'agent_stream_start', { agent: 'analysis' }.to_json)

  stream_synthesis(full_context, res)

  write_sse(res, 'thinking', { step: steps.length, label: "Done", total: steps.length + 1, done: true }.to_json)
  write_sse(res, 'done', '')
rescue => e
  $stderr.puts "Fatal: #{e.message}"
  write_sse(res, 'error', e.message)
  write_sse(res, 'done', '')
end

def stream_synthesis(context, res)
  agent = AGENTS[:analysis]
  url = agent[:provider] == :openrouter ? OPENROUTER_URL : GROQ_URL
  api_key = agent[:provider] == :openrouter ? next_openrouter_key : next_groq_key

  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 120
  http.open_timeout = 15

  req = Net::HTTP::Post.new(uri)
  req['Content-Type'] = 'application/json'
  req['Authorization'] = "Bearer #{api_key}"
  req['HTTP-Referer'] = 'http://localhost:3001' if agent[:provider] == :openrouter

  req.body = {
    model: agent[:model],
    messages: [
      { role: 'system', content: ANALYSIS_SYSTEM },
      { role: 'user', content: context }
    ],
    stream: true,
    temperature: 0.7,
    max_tokens: 4096
  }.to_json

  http.request(req) do |response|
    unless response.code.to_i == 200
      error_body = response.body rescue 'unknown'
      raise "Synthesis error #{response.code}: #{error_body}"
    end
    response.read_body do |chunk|
      chunk.each_line do |line|
        next unless line.start_with?('data: ')
        data = line[6..].strip
        next if data == '[DONE]' || data.empty?
        begin
          parsed = JSON.parse(data)
          delta = parsed.dig('choices', 0, 'delta', 'content') || ''
          write_sse(res, 'token', delta) unless delta.empty?
        rescue JSON::ParserError
        end
      end
    end
  end
end

# ===== SERVER =====
server = WEBrick::HTTPServer.new(
  Port: PORT,
  DocumentRoot: File.join(__dir__),
  Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO),
  AccessLog: [[File.open(File::NULL, 'w'), WEBrick::AccessLog::COMMON_LOG_FORMAT]]
)

# Mount API with mount_proc instead
server.mount_proc '/api/chat' do |req, res|
  if req.request_method == 'OPTIONS'
    res.status = 204
    res['Access-Control-Allow-Origin'] = '*'
    res['Access-Control-Allow-Methods'] = 'POST, OPTIONS'
    res['Access-Control-Allow-Headers'] = 'Content-Type'
  elsif req.request_method == 'POST'
    handle_chat(req, res)
  else
    res.status = 405
    res.body = 'Method not allowed'
  end
end

trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }

puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts "  MULTI-AGENT AI CHAT SERVER"
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts "  OpenRouter keys: #{OPENROUTER_KEYS.length} (rotated)"
puts "  Groq keys: #{GROQ_KEYS.length} (rotated)"
puts "  Agents:"
AGENTS.each do |name, cfg|
  puts "    #{name}: #{cfg[:provider]} → #{cfg[:model]}"
end
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts "  URL: http://localhost:#{PORT}"
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

server.start
