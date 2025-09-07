# frozen_string_literal: true

class StripeEventHandler
  attr_accessor :params
  # See full list of events at https://stripe.com/docs/api/events/types
  ALL_HANDLED_EVENTS = %w{account.application.deauthorized account.updated capability.updated payout. charge. capital. radar. payment_intent.payment_failed}.freeze

  # Handle's a Stripe event. Calls out to the necessary modules
  # that handle different types of Stripe events.
  #
  # stripe_connect_account_id – the Stripe Account ID if the event is for
  #                             a connected Stripe Account, nil if the event
  #                             is for our Stripe Account
  def initialize(params)
    @params = params.to_hash.deep_symbolize_keys!
  end

  def handle_stripe_event
    unless ALL_HANDLED_EVENTS.any? { |evt| params[:type].to_s.starts_with?(evt) }
      Rails.logger.error("Unhandled event #{params[:type]}:: #{params}")
      return
    end

    # Check if event already processed
    stripe_event_id = params[:id]
    if ProcessedStripeEvent.already_processed?(stripe_event_id)
      Rails.logger.info("Stripe event #{stripe_event_id} already processed, skipping")
      return
    end

    stripe_connect_account_id = params[:user_id].present? ? params[:user_id] : params[:account]

    begin
      if stripe_connect_account_id.present? && stripe_connect_account_id != STRIPE_PLATFORM_ACCOUNT_ID
        if params && params[:type] == "account.application.deauthorized"
          handle_event_for_connected_account_deauthorized
        else
          with_stripe_error_handler do
            handle_event_for_connected_account(stripe_connect_account_id:)
          end
        end
      else
        handle_event_for_gumroad
      end

      # Mark event as processed
      ProcessedStripeEvent.mark_processed!(
        stripe_event_id,
        params[:type],
        stripe_account_id: stripe_connect_account_id,
        metadata: {
          processed_at: Time.current,
          handler_version: "enhanced_v1"
        }
      )
    rescue StandardError => e
      Rails.logger.error("Error processing Stripe event #{stripe_event_id}: #{e.message}")
      if Rails.env.staging?
        Rails.logger.error("Error while handling event with params #{params} :: #{e}")
      else
        raise e
      end
    end
  end

  private
    def stripe_event
      @_stripe_event ||= Stripe::Util.convert_to_stripe_object(params, {})
    end

    def handle_event_for_gumroad
      StripeChargeProcessor.handle_stripe_event(stripe_event) if stripe_event["type"].start_with?("charge.",
                                                                                                  "capital.",
                                                                                                  "radar.",
                                                                                                  "payment_intent.payment_failed")
    end

    def handle_event_for_connected_account(stripe_connect_account_id:)
      if stripe_event["type"].start_with?("charge.", "radar.", "payment_intent.payment_failed")
        StripeChargeProcessor.handle_stripe_event(stripe_event)
      elsif stripe_event["type"].start_with?("account.", "capability.")
        StripeMerchantAccountManager.handle_stripe_event(stripe_event)
      elsif stripe_event["type"].start_with?("payout.")
        StripePayoutProcessor.handle_stripe_event(stripe_event, stripe_connect_account_id:)
      end
    end

    def handle_event_for_connected_account_deauthorized
      params[:type] = "account.application.deauthorized" # Make sure type is always deauthorized
      deauthorized_stripe_event = Stripe::Util.convert_to_stripe_object(params, {})
      StripeMerchantAccountManager.handle_stripe_event_account_deauthorized(deauthorized_stripe_event)
    end

    def with_stripe_error_handler
      yield
    rescue StandardError => exception
      if exception.message.include?("Application access may have been revoked.")
        handle_event_for_connected_account_deauthorized
      elsif exception.message.include?("a similar object exists in test mode, but a live mode key was used to make this request")
        # noop, we can safely ignore these
      else
        raise exception
      end
    end
end
