require 'csv'
require 'neography'
require 'pry'

class Client
end

class Dictionary
  AIUEO = %w(
  ア イ ウ エ オ カ キ ク ケ コ ガ ギ グ ゲ ゴ サ シ ス セ ソ ザ ジ ズ ゼ ゾ タ チ ツ テ ト ダ ヂ ヅ デ ド ナ ニ ヌ ネ ノ
  ハ ヒ フ ヘ ホ バ ビ ブ ベ ボ パ ピ プ ペ ポ マ ミ ム メ モ ヤ ユ ヨ ラ リ ル レ ロ ワ ヲ ン
  )
  attr_reader :data, :head, :tail

  def initialize(file: nil)
    raise ArgumentError, '辞書を指定してください' unless file
    @data = CSV.read(file, headers: true)
    @head = {}
    @tail = {}
  end

  def build_relation
    @data.each do |word|
      hash = word.to_h
      hash['node'] = Neography::Node.create(hash)
      @head[word['phonetic'][0]].nil? ? @head[word['phonetic'][0]] = [hash] : @head[word['phonetic'][0]] << hash
      @tail[word['phonetic'][-1]].nil? ? @tail[word['phonetic'][-1]] = [hash] : @tail[word['phonetic'][-1]] << hash
    end

    @tail.each do |last_word, words|
      words.each do |word|
        @head[last_word].each do |target|
          word['node'].outgoing(:shiritori) << target['node']
        end
      end
    end
  end
end

Neography.configure do |c|
  c.server = 'localhost'
  c.authentication = :basic
  c.username = 'neo4j'
  c.password = 'neo4j'
end
