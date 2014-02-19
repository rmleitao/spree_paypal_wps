# need to create a new payment object in the order, otherwise the view partial will not render.
# it needs to generate a new payment with "identifier", that will be sent to paypal.

Spree::CheckoutController.class_eval do
  def edit
    if ((@order.state == "payment") && @order.valid?)
      if @order.payable_via_paypal?
        payment = Spree::Payment.new
        payment.amount = @order.total
        payment.payment_method = Spree::Order.paypal_payment_method
        @order.payments << payment
        payment.started_processing
        # render(:partial => 'checkout/paypal_checkout')
      end
    end
  end
end
