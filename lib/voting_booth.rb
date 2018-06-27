require 'logger'

module VotingBooth
  autoload :BotController, 'voting_booth/bot_controller'

  def self.run
    Telegram::Bot::UpdatesPoller.new(
      bot,
      BotController,
      logger: Logger.new(STDOUT)
    ).start
  end

  def self.bot
    @@bot ||= Telegram::Bot::Client.new(ENV['TG_TOKEN']).tap do |bot|
      bot.extend Telegram::Bot::Client::TypedResponse
    end
  end
end
