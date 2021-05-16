module Spree
  class OrdersController < ::BaseController
    include OrderCyclesHelper
    include Rails.application.routes.url_helpers

    layout 'darkswarm'

    ssl_required :show

    before_action :check_authorization
    rescue_from ActiveRecord::RecordNotFound, with: :render_404
    helper 'spree/products', 'spree/orders'

    respond_to :html
    respond_to :json

    before_action :set_current_order, only: :update
    before_action :filter_order_params, only: :update
    before_action :enable_embedded_shopfront

    prepend_before_action :require_order_authentication, only: :show
    prepend_before_action :require_order_cycle, only: :edit
    prepend_before_action :require_distributor_chosen, only: :edit
    before_action :check_hub_ready_for_checkout, only: :edit
    before_action :check_at_least_one_line_item, only: :update

    def show
      @order = Spree::Order.find_by!(number: params[:id])

      handle_stripe_response
    end

    def empty
      if @order = current_order
        @order.empty!
      end

      redirect_to main_app.cart_path
    end

    # Patching to redirect to shop if order is empty
    def edit
      @order = current_order(true)
      @insufficient_stock_lines = @order.insufficient_stock_lines
      @unavailable_order_variants = OrderCycleDistributedVariants.
        new(current_order_cycle, current_distributor).unavailable_order_variants(@order)

      if @order.line_items.empty?
        redirect_to main_app.shop_path
      else
        associate_user

        if @order.insufficient_stock_lines.present? || @unavailable_order_variants.present?
          flash.now[:error] = t("spree.orders.error_flash_for_unavailable_items")
        end
      end
    end

    def update
      @insufficient_stock_lines = []
      @order = order_to_update
      unless @order
        flash[:error] = t(:order_not_found)
        redirect_to(main_app.root_path) && return
      end

      # This action is called either from the cart page when the order is not yet complete, or from
      # the edit order page (frontoffice) if the hub allows users to update completed orders.
      if @order.contents.update_cart(order_params)
        @order.recreate_all_fees! # Enterprise fees on line items and on the order itself

        if @order.complete?
          @order.update_payment_fees!
          @order.create_tax_charge!
        end

        respond_with(@order) do |format|
          format.html do
            if params.key?(:checkout)
              @order.next_transition.run_callbacks if @order.cart?
              redirect_to main_app.checkout_state_path(@order.checkout_steps.first)
            elsif @order.complete?
              redirect_to main_app.order_path(@order)
            else
              redirect_to main_app.cart_path
            end
          end
        end
      else
        # Show order with original values, not newly entered ones
        @insufficient_stock_lines = @order.insufficient_stock_lines
        @order.line_items.reload
        respond_with(@order)
      end
    end

    def cancel
      @order = Spree::Order.find_by!(number: params[:id])
      authorize! :cancel, @order

      if CustomerOrderCancellation.new(@order).call
        flash[:success] = I18n.t(:orders_your_order_has_been_cancelled)
      else
        flash[:error] = I18n.t(:orders_could_not_cancel)
      end
      redirect_to request.referer || main_app.order_path(@order)
    end

    private

    def set_current_order
      @order = current_order(true)
    end

    def check_authorization
      session[:access_token] ||= params[:token]
      order = Spree::Order.find_by(number: params[:id]) || current_order

      if order
        authorize! :edit, order, session[:access_token]
      else
        authorize! :create, Spree::Order
      end
    end

    # Stripe can redirect here after a payment is processed in the backoffice.
    # We verify if it was successful here and persist the changes.
    def handle_stripe_response
      return unless params.key?("payment_intent")

      result = ProcessPaymentIntent.new(params["payment_intent"], @order).call!

      unless result.ok?
        flash.now[:error] = "#{I18n.t("payment_could_not_process")}. #{result.error}"
      end
      @order.reload
    end

    def filter_order_params
      if params[:order] && params[:order][:line_items_attributes]
        params[:order][:line_items_attributes] =
          remove_missing_line_items(params[:order][:line_items_attributes])
      end
    end

    def remove_missing_line_items(attrs)
      attrs.select do |_i, line_item|
        Spree::LineItem.find_by(id: line_item[:id])
      end
    end

    def discard_empty_line_items
      @order.line_items = @order.line_items.select { |li| li.quantity > 0 }
    end

    def require_order_authentication
      return if session[:access_token] || params[:token] || spree_current_user

      flash[:error] = I18n.t("spree.orders.edit.login_to_view_order")
      redirect_to main_app.root_path(anchor: "login?after_login=#{request.env['PATH_INFO']}")
    end

    def order_to_update
      return @order_to_update if defined? @order_to_update
      return @order_to_update = current_order unless params[:id]

      @order_to_update = changeable_order_from_number
    end

    # If a specific order is requested, return it if it is COMPLETE and
    # changes are allowed and the user has access. Return nil if not.
    def changeable_order_from_number
      order = Spree::Order.complete.find_by(number: params[:id])
      return nil unless order.andand.changes_allowed? && can?(:update, order)

      order
    end

    def check_at_least_one_line_item
      return unless order_to_update.andand.complete?

      items = params[:order][:line_items_attributes]
        .andand.select{ |_k, attrs| attrs["quantity"].to_i > 0 }

      if items.empty?
        flash[:error] = I18n.t(:orders_cannot_remove_the_final_item)
        redirect_to main_app.order_path(order_to_update)
      end
    end

    def order_params
      params.require(:order).permit(
        :distributor_id, :order_cycle_id,
        line_items_attributes: [:id, :quantity]
      )
    end
  end
end
