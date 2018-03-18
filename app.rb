require 'csv'
require 'json'
require 'logger'
require 'neography'
require 'net/http'
require 'pry'
require 'uri'

class Client
  API_SERVER_ADDRESS = 'http://api.h-mp-recruit.jp'
  ShiritoriError = Class.new(StandardError)
  attr_reader :dic

  def initialize(level: nil, poem_id: 1)
    @play_id = nil
    @level = level
    @poem_id = (level == 1 ? 101 : poem_id) # level 1では和歌が指定されている
    uri = URI.parse(API_SERVER_ADDRESS)
    @client = Net::HTTP.new(uri.host, uri.port)
    @user_objective_word_called = false
    @bot_objective_word_registered = false
    @current_word = 'しりとり'
    @current_target = nil
    @logger = Logger.new(STDOUT)
  end

  def setup
    @dic = Dictionary.new(file: dictionary_path(level: @level))
    @dic.register_to_db(poem_id: @poem_id)
    @current_target = @dic.poem[0]['word'] # 上の句
    @logger.info 'finish setup'
  end

  def dictionary_path(level: nil)
    case level
    when 1
      'dataset/03_words_level_1.csv'
    when 2
      'dataset/04_words_level_2.csv'
    when 3
      'dataset/05_words_level_3.csv'
    else
      raise ArgumentError, 'Invalid level'
    end
  end

  def start
    param = "word=しりとり&level=#{@level}&user_objective_word=#{@dic.poem[0]['word']}&bot_objective_word=#{@dic.poem[1]['word']}"
    @logger.info "post /start_shiritori with param: #{param}"
    response = JSON.parse(@client.post('/start_shiritori', param).body, symbolize_names: true)

    if response[:status] == 'error'
      raise ShiritoriError, response[:message]
    end
    @play_id = response[:play_id]
    @current_word = response[:word]
    @dic.remove_word(word: 'しりとり')
    @logger.info "response: #{response}"
    response
  end

  def turn(play_id: nil)
    @play_id = play_id if play_id
    word = @dic.next_word(start: @current_word, goal: @current_target)
    if @bot_objective_word_registered && word == @current_target
      word = @dic.next_word(start: @current_word, goal: @dic.detect_target(ignore: @current_word))
    end
    param = "play_id=#{@play_id}&word=#{word}"
    @logger.info "post /shiritori with param: #{param}"
    response = JSON.parse(@client.post('/shiritori', param).body, symbolize_names: true)
    @logger.info "response: #{response}"
    @current_word = response[:word]

    if word== @dic.poem[0]['word']
      @user_objective_word_called = true
    end

    @dic.remove_word(word: word)

    response
  end

  def play
    start

    loop do
      res = turn

      case res[:status]
      when 'ok'
      when 'error'
        raise ShiritoriError, response[:message]
      when 'success'
        break
      end

      if @user_objective_word_called && !@bot_objective_word_registered
        @logger.info "call #{@current_target} succeeded!"
        @dic.register_shimonoku_to_db
        @bot_objective_word_registered = true
        @current_target = @dic.aboid_call_shimonoku_by_me
      end
    end
  end
end

class Dictionary
  AIUEO = %w(
  ア イ ウ エ オ カ キ ク ケ コ ガ ギ グ ゲ ゴ サ シ ス セ ソ ザ ジ ズ ゼ ゾ タ チ ツ テ ト ダ ヂ ヅ デ ド ナ ニ ヌ ネ ノ
  ハ ヒ フ ヘ ホ バ ビ ブ ベ ボ パ ピ プ ペ ポ マ ミ ム メ モ ヤ ユ ヨ ラ リ ル レ ロ ワ ヲ ン
  )
  POEMS_DATA = 'dataset/02_100_poems.csv'
  attr_reader :data, :head, :tail
  attr_accessor :start_poem_node, :end_poem_node

  def initialize(file: nil)
    raise ArgumentError, '辞書を指定してください' unless file
    @data = CSV.read(file, headers: true, encoding: 'UTF-8')
    @poem_id = nil
    @poems = CSV.read(POEMS_DATA, headers: true, encoding: 'UTF-8')
    @head = {}
    @tail = {}
    @nodes = []
    @start_poem_node = nil
    @end_poem_node = nil
    @neo4j = Neography::Rest.new
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::INFO
    build_index
  end

  def poem
    @poem ||= @poems.select do |poem|
      poem['poem_id'].to_i == @poem_id
    end
  end

  def register_to_db(poem_id: nil)
    @neo4j.execute_query('MATCH (n) OPTIONAL MATCH (n)-[r]-() DELETE n,r')
    @poem_id = poem_id
    @data.each do |word|
      h = word.to_h
      h['node'] = register_word_to_db(word)
      @head[word['phonetic'][0]] << h
      @tail[word['phonetic'][-1]] << h
    end
    
    if @poem_id
      poem.each do |word|
        next if word['kind'] == '下の句' # 下の句は初回登録しない
        h = word.to_h
        h['node'] = register_poem_to_db(word)
        @head[word['phonetic'][0]] << h
        @tail[word['phonetic'][-1]] << h
        word['kind'] == '上の句' ? @start_poem_node = h['node'] : @end_poem_node = h['node']
      end
    end

    @head.each do |phonetic, nodes|
      nodes.each {|n| build_relation(n)}
    end
  end

  def build_relation(word)
    #return unless @head[word['phonetic'][-1]]
    #@head[word['phonetic'][-1]].each do |target|
    #  word['node'].outgoing(:shiritori) << target['node']
    #  @logger.debug "set relationship #{word['word']} -> #{target['word']}"
    #end
    return unless @tail[word['phonetic'][0]]
    @tail[word['phonetic'][0]].each do |target|
      target['node'].outgoing(:shiritori) << word['node']
      @logger.debug "set relationship #{target['word']} -> #{word['word']}"
    end
  end

  def register_word_to_db(word)
    n =  Neography::Node.create({word: word['word'], phonetic: word['phonetic']})
    n.set_labels('word')
    @nodes << n
    n
  end

  def register_poem_to_db(poem)
    n =  Neography::Node.create({word: poem['word'], phonetic: poem['phonetic'], kind: poem['kind']})
    n.set_labels('poem')
    @nodes << n
    n
  end

  def register_shimonoku_to_db
    poem.each do |p|
      if p['kind'] == '下の句'
        hash = p.to_h
        hash['node'] = register_poem_to_db(p)
        build_relation(hash)
        @logger.debug "registered #{p['word']} to dictionary"
      end
    end
  end

  def next_word(start: nil, goal: nil)
    @logger.info "search shortest_path between #{start} and #{goal}"
    return start if start == goal
    start_node = Neography::Node.load(@neo4j.execute_query("MATCH (n{word: '#{start}'}) RETURN id(n);")['data'][0][0])
    goal_node = Neography::Node.load(@neo4j.execute_query("MATCH (n{word: '#{goal}'}) RETURN id(n);")['data'][0][0])
    start_node.shortest_path_to(goal_node).outgoing(:shiritori).depth(:all).nodes.first.map {|n| n.word}[1]
  end

  def remove_word(word: nil)
    remove_word_from_tree(word)
    Neography::Node.load(@neo4j.execute_query("MATCH (n{word: '#{word}'}) RETURN id(n);")['data'][0][0]).del
    @logger.info "removed #{word} from dictionary"
  end

  def detect_target(ignore: nil)
    @logger.debug 'detect target'
    @logger.debug "#{@tail[poem[1]['phonetic'][0]].inspect}"
    @tail[poem[1]['phonetic'][0]].find_all {|n| n['word'] != poem[1]['word'] && n['word'] != ignore }.sample['word']
  end

  def aboid_call_shimonoku_by_me
    if @tail[poem[1]['phonetic'][0]].count == 1
      w = @tail[poem[1]['phonetic'][0]].first['word']
      @logger.debug "set target to #{w} for aboid call shimonoku by me"
      w
    else
      poem[1]['word']
    end
  end

  private

  def build_index
    AIUEO.each do |kana|
      @head[kana] = []
      @tail[kana] = []
    end
  end

  def remove_word_from_tree(word)
    i = @nodes.find_index {|n| n['word'] == word}
    @head[@nodes[i]['phonetic'][0]].delete_if do |dic|
      dic['word'] == word
    end

    @tail[@nodes[i]['phonetic'][-1]].delete_if do |dic|
      dic['word'] == word
    end
    @nodes.delete_at(i)
  end
end

Neography.configure do |c|
  c.server = 'neo4j'
  c.authentication = :basic
  c.username = 'neo4j'
  c.password = 'neo4j'
end

# require_relative 'app'
# dic = Dictionary.new(file: 'dataset/04_words_level_2.csv')
# dic.build_relation
