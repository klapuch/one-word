# frozen_string_literal: true

require 'net/http'
require 'nokogiri'
require 'json'
require 'firebase'
require_relative 'config.local'

class ContinualRange
  def initialize(from, to, step)
    @from = from
    @to = to
    @step = step
    @max = to
  end

  def current
    [@from, @from + @step]
  end

  def next
    _, to = current
    @from = to + 1
    @to += @step
  end

  def last?
    from, = current
    from >= @max
  end

  def steps
    (@from..@to).to_a
  end
end

class SlovnikCizichSlovPage
  def initialize(from, to)
    @from = from
    @to = to
  end

  def html
    Net::HTTP.get(URI(url))
  end

  def url
    url = format('%s/web.php/top100', base_url)
    url += format('/%d-%d', @from, @to) unless @from.zero?
    url
  end

  def base_url
    'https://slovnik-cizich-slov.abz.cz'
  end
end

class SlovnikCizichSlovWords
  def initialize(pages)
    @pages = pages
  end

  def all
    position = 0
    words = []
    @pages.all.each do |page|
      html = Nokogiri::HTML(page.html())
      values = html.xpath('//div[@id="content_part"]//div[@style]/a/text()')
      links = html.xpath('//div[@id="content_part"]//div[@style]/a/@href')
      links = absolute_links(page.base_url, links)
      values.zip(links).each do |word|
        value, link = word
        position += 1
        words.push({ position: position, value: value, link: link })
      end
    end
    words
  end

  def absolute_link(url, path)
    "#{url}/#{path.to_s.delete_prefix('/')}"
  end

  def absolute_links(url, links)
    links.map { |path| absolute_link(url, path) }
  end
end

class SlovnikCizichSlovPages
  def all
    pages = []
    range = ContinualRange.new(0, 1000, 50)
    until range.last?
      from, to = range.current
      pages.append(SlovnikCizichSlovPage.new(from, to))
      range.next
    end
    pages
  end
end

class UniqueWords
  def initialize(origin)
    @origin = origin
  end

  def all
    words = []
    @origin.all.select do |word|
      unique = words.none? word[:value]
      words.push(word[:value])
      unique
    end
  end
end

class Telegram
  def initialize(token)
    @token = token
  end

  def request(endpoint, parameters)
    Net::HTTP.post(
      URI(url(endpoint)),
      parameters.to_json,
      'Content-Type': 'application/json'
    )
  end

  def url(endpoint)
    format('https://api.telegram.org/bot%s/%s', @token, endpoint)
  end
end

class TelegramMessage
  def initialize(client, text, chatId)
    @client = client
    @text = text
    @chatId = chatId
  end

  def send
    @client.request(
      'sendMessage',
      {
        chat_id: @chatId,
        text: @text,
        parse_mode: 'html',
        disable_web_page_preview: true
      }
    )
  end
end

class FirebaseWord
  DOCUMENT = 'words'
  def initialize(client)
    @client = client
  end

  def value
    response = @client.get(DOCUMENT, { orderBy: '"position"', limitToFirst: 1 })
    raise format('Response was not successfull - %s', response.raw_body) unless response.success?
    raise 'No more words.' if response.body.nil?

    id, word = response.body.first
    @id = id
    word
  end

  def delete
    raise 'No word to delete.' if @id.nil?

    response = @client.delete("#{DOCUMENT}/#{@id}")
    raise format('Response was not successfull - %s', response.raw_body) unless response.success?
  end
end

class FirebaseWords
  DOCUMENT = 'words'
  def initialize(origin, firebase)
    @origin = origin
    @firebase = firebase
  end

  def add
    @origin.all.each do |word|
      @firebase.push(
        DOCUMENT,
        {
          position: word[:position],
          value: word[:value],
          link: word[:link]
        }
      )
    end
  end
end

class Feed
  def initialize(firebase, telegram, subscribers)
    @firebase = firebase
    @telegram = telegram
    @subscribers = subscribers
  end

  def consume
    word = FirebaseWord.new(@firebase)
    value = word.value()
    message = format('<a href="%s">%s</a>', value['link'], value['value'])
    @subscribers.each { |subscriber| TelegramMessage.new(@telegram, message, subscriber).send }
    word.delete
  end
end

firebase = Firebase::Client.new(
  CONFIG[:firebase][:uri],
  File.open(CONFIG[:firebase][:key_uri]).read
)

def import(firebase)
  FirebaseWords.new(
    UniqueWords.new(SlovnikCizichSlovWords.new(SlovnikCizichSlovPages.new)),
    firebase
  ).add
end

def consume(firebase)
  telegram = Telegram.new(CONFIG[:telegram][:token])

  Feed.new(firebase, telegram, CONFIG[:telegram][:subscribers]).consume
end

case ARGV[0]
when 'import'
  import(firebase)
when 'consume'
  consume(firebase)
else
  raise 'You must pass one of [import, consume] option.'
end
