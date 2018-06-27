require 'securerandom'

module VotingBooth
  class BotController < ::Telegram::Bot::UpdatesController
    include Telegram::Bot::UpdatesController::CallbackQueryContext
    include Telegram::Bot::UpdatesController::Session
    include Telegram::Bot::UpdatesController::MessageContext

    self.session_store = :file_store, File.join($ROOT, 'tmp')
    self.logger = Logger.new(STDOUT)

    def start!(*)
      session[:hosted_votes] ||= {}
      session[:building_vote] = {
        id: SecureRandom.hex(16),
        choices: []
      }

      save_context :host_vote
      respond_with :message, text: <<~MSG
        Welcome to host a new voting!

        Describe your topic:
        MSG
    end

    def host_vote(*)
      session[:building_vote][:topic] = payload.text

      save_context :provide_description
      respond_with :message,
        reply_markup: build_list_keyboard(
          { text: 'Skip', callback_data: "skip_description:#{session[:building_vote][:id]}" }
        ),
        text: <<~MSG
          Nice topic "#{payload.text}"!

          Now, please provide some description to this vote:
          MSG
    end

    def provide_description(*)
      _provide_description(payload.text)
    end
    def skip_description_callback_query(vote_id)
      return unless message_context_session[:context] == :provide_description
      return unless session[:building_vote][:id] == vote_id

      _provide_description('')
    end

    def provide_choice(*)
      session[:building_vote][:choices] << payload.text

      save_context :provide_choice
      respond_with :message,
        text: 'Next choice?',
        reply_markup: build_list_keyboard(
          { text: 'Done', callback_data: "save_vote:#{session[:building_vote][:id]}" }
        )
    end

    def save_vote_callback_query(vote_id)
      return unless message_context_session[:context] == :provide_choice
      return unless session[:building_vote][:id] == vote_id

      vote = session.delete(:building_vote)
      vote[:voters] = {}

      session[:hosted_votes][vote[:id]] = vote

      save_context nil
      respond_with :message,
        parse_mode: 'markdown',
        disable_web_page_preview: true,
        text: build_vote_status(vote),
        reply_markup: build_list_keyboard(
          { text: 'Publish', switch_inline_query: vote[:topic] },
          { text: 'Refresh', callback_data: "refresh_vote:#{vote[:id]}" },
        )
    end

    def refresh_vote_callback_query(vote_id)
      return unless session[:hosted_votes].key? vote_id

      vote = session[:hosted_votes][vote_id]
      edit_message :text,
        parse_mode: 'markdown',
        disable_web_page_preview: true,
        text: build_vote_status(vote),
        reply_markup: build_list_keyboard(
          { text: 'Publish', switch_inline_query: vote[:topic] },
          { text: 'Refresh', callback_data: "refresh_vote:#{vote[:id]}" },
        )
    end

    def inline_query(query = '', _offset = nil)
      query = query.strip
      votes = query.empty? ? [] : session[:hosted_votes].select { |id, vote| vote[:topic].include?(query) }.values

      answer_inline_query(votes.map do |vote|
        {
          type: 'article',
          id: vote[:id],
          title: vote[:topic],
          description: vote[:description],
          input_message_content: {
            disable_web_page_preview: true,
            message_text: build_vote_status(vote),
            parse_mode: 'markdown'
          },
          reply_markup: build_list_keyboard(*vote[:choices].map.with_index do |choice, idx|
            { text: choice, callback_data: "just_vote:#{from.id}:#{vote[:id]}:#{idx}" }
          end)
        }
      end)
    end

    def just_vote_callback_query(data)
      creator_id, vote_id, choice_idx = data.split(':')
      return if creator_id.nil? || vote_id.nil? || choice_idx.nil?
      choice_idx = choice_idx.to_i

      creator_session = self.class.build_session("#{bot.username}:#{creator_id}")
      return unless creator_session.exists?
      return unless creator_session.key?(:hosted_votes)
      return unless creator_session[:hosted_votes].key?(vote_id)

      vote = creator_session[:hosted_votes][vote_id]
      return unless choice_idx < vote[:choices].count

      vote[:voters][from.id] ||= {
        name: [from.first_name, from.last_name].compact.join(' '),
        choices: []
      }

      vote[:voters][from.id][:choices].delete(choice_idx) do # not found
        vote[:voters][from.id][:choices] << choice_idx
      end
      creator_session.commit

      edit_message :text,
        parse_mode: 'markdown',
        text: build_vote_status(vote),
        reply_markup: build_list_keyboard(*vote[:choices].map.with_index do |choice, idx|
          { text: choice, callback_data: "just_vote:#{creator_id}:#{vote[:id]}:#{idx}" }
        end)
    end

    private

    def session_key
      "#{bot.username}:#{from.id}" if from
    end

    def build_list_keyboard(*keys)
      Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keys.map { |key| [key] }).attributes
    end

    def _provide_description(desc)
      session[:building_vote][:description] = desc

      save_context :provide_choice
      respond_with :message, text: 'Now, provide your first choice:'
    end

    def build_vote_status(vote)
      choice_statuses = vote[:choices].map.with_index do |choice, idx|
        voters = vote[:voters].select { |id, voter| voter[:choices].include? idx }.values

        <<~MSG
          *#{choice}* \\[#{voters.count}]
          #{voters.map.with_index { |voter, i| "#{i < voters.count - 1 ? '├' : '‎└'}#{voter[:name]}\n" }.join('')}
          MSG
      end.join('')

      <<~MSG
        *#{vote[:topic]}*
        #{vote[:description]}

        #{choice_statuses}
        There's #{vote[:voters].count} voter(s) already.
        Last updated at #{Time.now.iso8601}
        MSG
    end
  end
end
