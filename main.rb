require 'net/http'
require 'nokogiri'
require 'json'
require 'firebase'
require_relative 'config.local.rb'

class ContinualRange
  def initialize(from, to, step)
    @from = from
    @to = to
    @step = step
    @max = to
  end

  def current()
    return [@from, @from + @step]
  end

  def next()
    from, to = self.current()
    @from = to + 1
    @to = @to + @step
  end

  def last?()
    from, to = self.current()
    from >= @max
  end

  def steps()
    (@from .. @to).to_a
  end

  private
    @from
    @to
    @max
    @step
end


class SlovnikCizichSlovPage
  def initialize(from, to)
    @from = from
    @to = to
  end

  def html()
    Net::HTTP.get(URI(self.url()))
  end

  def url()
    url = '%s/web.php/top100' % [self.base_url()]
    unless @from == 0
      url += '/%d-%d' % [@from, @to]
    end
    url
  end

  def base_url()
    'https://slovnik-cizich-slov.abz.cz'
  end

  private
    @from
    @to
end


class SlovnikCizichSlovWords
  def initialize(pages)
    @pages = pages
  end

  def all()
    position = 0
    words = []
    @pages.all().each do |page|
        html = Nokogiri::HTML(page.html())
        values = html.xpath('//div[@id="content_part"]//div[@style]/a/text()')
        links = html.xpath('//div[@id="content_part"]//div[@style]/a/@href')
        links = self.absolute_links(page.base_url(), links)
        values.zip(links).each do |word|
          value, link = word
          position += 1
          words.push({:position => position, :value => value, :link => link})
        end   
    end
    words
  end

  def absolute_link(url, path)
    url + '/' + path.to_s.delete_prefix('/')
  end

  def absolute_links(url, links)
    links.map{|path| self.absolute_link(url, path)}
  end

  private
    @pages
end


class SlovnikCizichSlovPages
  def all()
    pages = []
    range = ContinualRange.new(0, 1000, 50)
    while not range.last?
        from, to = range.current()
        pages.append(SlovnikCizichSlovPage.new(from, to))
        range.next()
    end
    pages
  end
end


class UniqueWords
  def initialize(origin)
    @origin = origin
  end

  def all()
    words = []
    @origin.all().select{|word|
      unique = words.none? word[:value]
      words.push(word[:value])
      unique
    }
  end

  private
    @origin
end


class Telegram
  def initialize(token)
    @token = token
  end

  def request(endpoint, parameters)
    Net::HTTP.post(
      URI(self.url(endpoint)),
      parameters.to_json(),
      'Content-Type': 'application/json',
    )
  end

  def url(endpoint)
    'https://api.telegram.org/bot%s/%s' % [@token, endpoint]
  end
end


class TelegramMessage
  def initialize(client, text, chatId)
    @client = client
    @text = text
    @chatId = chatId
  end

  def send()
    @client.request(
      'sendMessage',
      {
        chat_id: @chatId,
        text: @text,
        parse_mode: 'html',
        disable_web_page_preview: true,
      }
    )
  end

  private
    @client
    @text
    @chatId
end


class FirebaseWord
  DOCUMENT = 'words'
  def initialize(client)
    @client = client
  end

  def value()
    response = @client.get(DOCUMENT, {orderBy: '"position"', limitToFirst: 1})
    unless response.success?
      raise 'Response was not successfull - %s' % [response.raw_body]
    end
    if response.body.nil?
      raise 'No more words.'
    end
    id, word = response.body.first()
    @id = id
    word
  end

  def delete()
    if @id.nil?
      raise 'No word to delete.'
    end
    response = @client.delete(DOCUMENT + '/' + @id)
    unless response.success?
      raise 'Response was not successfull - %s' % [response.raw_body]
    end
  end

  private
    @client
    @id
end


class FirebaseWords
  DOCUMENT = 'words'
  def initialize(origin, firebase)
    @origin = origin
    @firebase = firebase
  end

  def add()
    @origin.all().each{|word|
      @firebase.push(
        DOCUMENT,
        {
          position: word[:position],
          value: word[:value],
          link: word[:link],
        }
      )
    }
  end

  private
    @origin
    @firebase
end


class Feed
  def initialize(firebase, telegram, subscribers)
    @firebase = firebase
    @telegram = telegram
    @subscribers = subscribers
  end

  def consume()
    word = FirebaseWord.new(@firebase)
    value = word.value()
    message = '<a href="%s">%s</a>' % [value['link'], value['value']]
    @subscribers.each{|subscriber| TelegramMessage.new(@telegram, message, subscriber).send()}
    word.delete()
  end

  private
    @firebase
    @telegram
    @subscribers
end


firebase = Firebase::Client.new(
  CONFIG[:firebase][:uri],
  File.open(CONFIG[:firebase][:key_uri]).read(),
)

def import(firebase)
  FirebaseWords.new(
    UniqueWords.new(SlovnikCizichSlovWords.new(SlovnikCizichSlovPages.new())),
    firebase,
  ).add()
end

def consume(firebase)
  telegram = Telegram.new(CONFIG[:telegram][:token])
  
  Feed.new(firebase, telegram, CONFIG[:telegram][:subscribers]).consume()
end

case ARGV[0]
when 'import'
  import(firebase)
when 'consume'
  consume(firebase)
else
  raise 'You must pass one of [import, consume] option.'
end

