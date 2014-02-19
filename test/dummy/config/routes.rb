Rails.application.routes.draw do

  mount SpreePaypalWps::Engine => "/spree_paypal_wps"
end
