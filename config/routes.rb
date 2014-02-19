Spree::Core::Engine.routes.draw do
	resources :payment_notifications, :only => [:create]
end
