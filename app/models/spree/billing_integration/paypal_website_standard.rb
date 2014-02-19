class Spree::BillingIntegration::PaypalWebsiteStandard < Spree::BillingIntegration

  require 'rbconfig'

  preference :account_email, :string
  preference :ipn_notify_host, :string
  preference :ipn_secret, :string
  preference :success_url, :string
  preference :paypal_url, :string, :default => 'https://www.paypal.com/cgi-bin/webscr'
  preference :sandbox_url, :string, :default => 'https://www.sandbox.paypal.com/cgi-bin/webscr'
  preference :encryption, :boolean, :default => false
  preference :certificate_id, :string
  preference :currency, :string, :default => "EUR"
  preference :language, :string, :default => "en"
  preference :page_style, :string
  preference :populate_address, :boolean, :default => true

  def payment_profiles_supported?
    false
  end

  # rmleitao
  # so that /models/spree/payment/processing.rb doesn't try to contact a payment gateway to capture money automatically.
  # with paypal, the money has already been captured.
  def source_required?
    false
  end

end
