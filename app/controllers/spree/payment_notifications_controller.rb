module Spree
  class PaymentNotificationsController < BaseController
    protect_from_forgery :except => [:create]
    skip_before_filter :restriction_access
    
    def create
      payment_method = Spree::BillingIntegration::PaypalWebsiteStandard.first
      if(payment_method.preferred_encryption && (params[:secret] != payment_method.preferred_ipn_secret))
        logger.info "PayPal_Website_Standard: attempt to send an IPN with invalid secret"
        raise Exception
      end

      case params[:txn_type]
      when "recurring_payment"
        # TODO
      when "recurring_payment_expired"
        # TODO
      when "recurring_payment_failed"
        # TODO
      when "recurring_payment_profile_created"
        # TODO
      when "recurring_payment_profile_canceled"
        # TODO
      when "recurring_payment_skipped"
        # TODO
      when "recurring_payment_suspended"
        # TODO
      when "recurring_payment_suspended_due_to_max_failed_payment"
        # TODO
      when "subscr_signup"
        # when a user created a new subscription.
        # create a subscription object, attach the original order to it.
        # when we redirect the user to paypal, we are sending order.number in the invoice field.
        # when paypal notifies that a subscription has been created, it sends that order number in the invoice field.
        # it also sends its internal subscription_id, which we should use, 
        # given that every subsquent payment will use that subscription_id to identify it.
        @order = Spree::Order.find_by_number(params[:invoice])
        if @order.nil?
          logger.info "PayPal IPN processing error [subscr_signup]: Order #{params[:invoice]} not found."
          raise Exception
        end

        # create and save the payment notification object
        Spree::PaymentNotification.create!(
          :params => params,
          :order_id => @order.id,
          :status => "subscription_created",
          :transaction_id => nil
        )

        # Check if the user has previous subscriptions. if so, we should cancel them.
        # Important: there is an IPN for subscription cancelling. From my tests this doesn't conflict because apparently, 
        # when a subscription is cancelled via API call, as we're doing here, no IPN is triggered, so we will not be cancelling
        # the previous subscription twice.
        @order.user.subscriptions.with_state("ongoing").each do |subscription|
          # cancel the paypal subscription
          data = {
            :version => "109.0",
            :method => "ManageRecurringPaymentsProfileStatus",
            :profileid => subscription.paypal_subscription_id,
            :action => "Cancel",
            :note => "Cancelled due to plan upgrade."
          }
          p = PaypalNVP.new(payment_method.preferred_test_mode)
          result = p.call_paypal(data)
          if result["ACK"] == "Success"
            logger.info "PayPal IPN info [subscr_signup]: Subscription #{subscription.paypal_subscription_id} cancelled in PayPal."
          else
            logger.info "PayPal IPN error [subscr_signup]: Subscription #{subscription.paypal_subscription_id} failed to cancel in PayPal."
          end
          # cancel the database subscription
          subscription.cancel
          logger.info "PayPal IPN info [subscr_signup]: Subscription #{subscription.paypal_subscription_id} cancelled in Spree."
        end

        # create the subscription object
        Spree::Subscription.create!(
          :user_id => @order.user_id,
          :paypal_invoice => params[:invoice],
          :paypal_subscription_id => params[:subscr_id],
          :original_order_id => @order.id
        )

        # cancel the original order
        @order.cancel

      when "subscr_payment"
        # when a payment for a subscription has landed.
        # create a new order, based on the original one saved.
        # we know which Subscription it is, because it sends the subscription_id field set.
        # then we should fetch that subscription's original order and clone it.

        # fetch the Order
        @order = Spree::Order.find_by_number(params[:invoice])
        if @order.nil?
          logger.info "PayPal IPN processing error [subscr_payment]: Order #{params[:invoice]} not found."
          raise Exception
        end

        @subscription = Spree::Subscription.find_by_paypal_subscription_id(params[:subscr_id])
        if @subscription.nil?
          logger.info "PayPal IPN processing error [subscr_payment]: Subscription #{params[:subscr_id]} not found."
          raise Exception
        end

        # store the PaymentNotification in the db
        Spree::PaymentNotification.create!(
          :params => params,
          :order_id => @order.id,
          :status => params[:payment_status],
          :transaction_id => params[:txn_id]
        )

        # create and transition the Payment object
        @payment = Spree::Payment.new
        @payment.amount = BigDecimal.new(params[:mc_gross])
        @payment.payment_method = Spree::Order.paypal_payment_method

        # create a new order, cloning the original one.
        new_order = @order.dup
        @payment.order = new_order
        @payment.save

        @subscription.orders << new_order

        # clone its line_items
        @order.line_items.each do |line_item|
          new_line_item = line_item.dup
          new_order.line_items << new_line_item
        end

        # clone its adjustments
        @order.adjustments.each do |adjustment|
          new_adjustment = adjustment.dup
          new_order.adjustments << new_adjustment
        end

        # clone its shipment
        @order.shipments.each do |shipment|
          new_shipment = shipment.dup
          new_order.shipments << new_shipment
        end

        # add the transaction_id to the new order, so we know what generated it.
        new_order.paypal_transaction_id = params[:txn_id]

        # Check the PayPal IPN status. If complete, complete the payment.
        # All other states should render the payment as failed
        case params[:payment_status]
        when "Completed"
          # The Payment has been captured, and if IPN says so, the money is in the PayPal account.
          # So it's safe to say the Payment can be "completed"
          @payment.complete!
        else
          @payment.failure!
        end
        new_order.save!

        if !@order.completed?
          @order.update_attribute(:completed_at, Time.now)
          @order.cancel
        end

        # transition the order to "complete"
        Order.transaction do
          #order = new_order
          until new_order.state == "complete"
            if new_order.next!
              new_order.update!
              state_callback(:after)
            end
          end
        end

        # when the order is completed, a trigger will automatically be called to consume user credits.
        # fetch that amount and refund in paypal.
        if !new_order.credit_transaction.nil?
          logger.info "PayPal IPN info [subscr_payment]: Consumed user credits. Started PayPal refund processing."
          if new_order.credit_transaction.amount >= @payment.amount
            data = {
              :version => "109.0",
              :method => "RefundTransaction",
              :refundtype => "Full",
              :transactionid => params[:txn_id]
            }
            logger.info "PayPal IPN info [subscr_payment]: Processing full refund."
          else
            data = {
              :version => "109.0",
              :method => "RefundTransaction",
              :refundtype => "Partial",
              :amt => new_order.credit_transaction.amount,
              :transactionid => params[:txn_id]
            }
            logger.info "PayPal IPN info [subscr_payment]: Processing partial refund of #{new_order.credit_transaction.amount}."
          end

          p = PaypalNVP.new(payment_method.preferred_test_mode)
          result = p.call_paypal(data)
          logger.info "PayPal IPN info [subscr_payment] NVP Refund response: #{result}"
        end

      when "subscr_modify"
        # when a user modifies a subscription.
      when "subscr_failed"
        # when a payment failed.
        # a payment failed, we shouldn't need to do anything.
        # maybe in the future just update a count of failed_payments in the subscription object.
      when "subscr_eot"
        # when a suscription naturally ended.
        # just change the subscription state, no new payments will be received, so no new orders will be generated.

        @subscription = Spree::Subscription.find_by_paypal_subscription_id(params[:subscr_id])
        if @subscription.nil?
          logger.info "PayPal IPN processing error [subscr_eot]: Subscription #{params[:subscr_id]} not found."
          raise Exception
        end

        Spree::PaymentNotification.create!(
          :params => params,
          :order_id => @order.id,
          :status => "subscription_created",
          :transaction_id => nil
        )

        @subscription.end

      when "subscr_cancel"
        # when a suscription was cancelled. either:
        # - max failed attempts reached.
        # - admin cancelled the subscription.
        # - user cancelled the subscription.
        # just change the subscription state, no new payments will be received, so no new orders will be generated.

        @subscription = Spree::Subscription.find_by_paypal_subscription_id(params[:subscr_id])
        if @subscription.nil?
          logger.info "PayPal IPN processing error [subscr_eot]: Subscription #{params[:subscr_id]} not found."
          raise Exception
        end

        Spree::PaymentNotification.create!(
          :params => params,
          :order_id => nil,
          :status => "subscription_cancelled",
          :transaction_id => nil
        )

        if !@subscription.cancelled?
          @subscription.cancel
        end
      when "cart"
        @order = Spree::Order.find_by_number(params[:invoice])
        if @order.nil?
          logger.info "PayPal IPN processing error: Order #{params[:invoice]} not found."
          raise Exception
        end

        Spree::PaymentNotification.create!(
          :params => params,
          :order_id => @order.id,
          :status => params[:payment_status],
          :transaction_id => params[:txn_id])
        
        # load the payment object; should have been created when order transitioned to "payment"
        existing_payment = @order.payments.find_by_identifier(params[:custom])
        if existing_payment.nil?
          logger.info "PayPal IPN processing error: Payment with identifier #{params[:custom]} not found for order #{params[:invoice]}."
          raise Exception
        end

        # Create payment for this order
        # Even though Spree automatically creates a Payment object once the user reaches the payment order state
        # we should create a new Payment that reflects exactly what Paypal IPN is telling us that was paid.
        # We need a Payment object in the state Checkout, so that the Order state machine can transition to completed
        @payment = Spree::Payment.new
        @payment.amount = BigDecimal.new(params[:mc_gross])
        @payment.payment_method = existing_payment.payment_method

        @order.payments << @payment

        @payment.payment_method = Spree::Order.paypal_payment_method
        @payment.started_processing!

        # Check the PayPal IPN status. If complete, complete the payment.
        # All other states should render the payment as failed
        case params[:payment_status]
        when "Completed"
          # The Payment has been captured, and if IPN says so, the money is in the PayPal account.
          # So it's safe to say the Payment can be "completed"
          @payment.complete!
        else
          @payment.failure!
        end
        @order.save!

        Order.transaction do
          order = @order
          until @order.state == "complete"
            if @order.next!
              @order.update!
              state_callback(:after)
            end
          end
        end

      end
      
      render :nothing => true
    end
    
    private

    # those methods are copy-pasted from CheckoutController
    # we cannot inherit from that class unless we want to skip_before_filter
    # half of calls in SpreeBase module
    def state_callback(before_or_after = :before)
      method_name = :"#{before_or_after}_#{@order.state}"
      send(method_name) if respond_to?(method_name, true)
    end
    
    def before_address
      @order.bill_address ||= Address.new(:country => default_country)
      @order.ship_address ||= Address.new(:country => default_country)
    end
    
    def before_delivery
      @order.shipping_method ||= (@order.rate_hash.first && @order.rate_hash.first[:shipping_method])
    end
    
    def before_payment
      current_order.payments.destroy_all if request.put?
    end
    
		#This isn't working here in payment_nofitications_controller since IPN will run on a different session
    def after_complete
      session[:order_id] = nil
    end
    
    def default_country
      Country.find Spree::BillingIntegration::PaypalWebsiteStandard::Config.default_country_id
    end
    
  end
end