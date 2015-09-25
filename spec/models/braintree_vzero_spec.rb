require 'spec_helper'

describe Spree::Gateway::BraintreeVzero, :vcr do

  context 'valid credentials' do

    let(:gateway) { create(:vzero_gateway) }
    let(:order) { OrderWalkthrough.up_to(:payment) }

    it 'generates token' do
      expect(gateway.client_token).to_not be_nil
    end

    describe '#purchase' do
      before { gateway.preferred_3dsecure = false }

      it 'returns suceess with valid nonce' do
        expect(gateway.purchase('fake-valid-nonce', order).success?).to be true
      end

      it 'returns false with invalid nonce' do
        expect(gateway.purchase('fake-invalid-nonce', order).success?).to be false
      end

      it 'does not store Transaction in Vault by default' do
        expect(gateway.purchase('fake-valid-nonce', order).transaction.credit_card_details.token).to be_nil
      end

      context 'with 3DSecure option turned on' do
        before { gateway.preferred_3dsecure = true }

        it 'performs 3DSecure check' do
          expect(gateway.purchase('fake-valid-debit-nonce', order).success?).to be false
        end

        it 'adds error to Order' do
          gateway.purchase('fake-valid-debit-nonce', order)
          expect(order.errors.values.flatten.include?(I18n.t(:three_d_secure, scope: 'braintree.error'))).to be true
        end
      end

      context 'using Vault' do
        before { gateway.preferred_store_payments_in_vault = :store_all }

        it 'stores Transaction' do
          card_vault_token = gateway.purchase('fake-valid-nonce', order).transaction.credit_card_details.token
          expect { Braintree::PaymentMethod.find(card_vault_token) }.not_to raise_error
        end
      end

    end

    describe '#complete_order' do

      before do
        gateway.preferred_3dsecure = false
        gateway.complete_order(order, gateway.purchase('fake-valid-nonce', order), gateway)
      end

      context 'with valid nonce' do
        it 'completes order with valid nonce' do
          expect(order.completed?).to be true
        end

        it 'creates Payment object with valid state' do
          expect(order.payments.first.state).to eq 'pending'
        end

        it 'updates Order state' do
          gateway.purchase('fake-valid-nonce', order)
          expect(order.payment_state).to eq 'balance_due'
        end
      end


      it 'returns false when payment cannot be validated' do
        expect(gateway.complete_order(order, gateway.purchase('fake-invalid-nonce', order), gateway)).to be false
        expect(order.completed?).to be false
      end

    end

    describe '#update_states' do

      before do
        gateway.preferred_3dsecure = false
        gateway.complete_order(order, gateway.purchase('fake-valid-nonce', order), gateway)
        order.payments.first.source.update_attribute(:transaction_id, '9drj68') #use already settled transaction
      end

      let!(:result) { Spree::BraintreeCheckout.update_states }

      it 'updates payment State' do
        expect(result[:changed]).to eq 1
      end

      it 'does not update completed Checkout on subsequent runs' do
        expect(result[:changed]).to eq 1
        expect(Spree::BraintreeCheckout.update_states[:changed]).to eq 0
      end

      it 'updates Order payment_state when Checkout is updated' do
        expect(order.reload.payment_state).to eq 'paid'
      end

      it 'updates Payment state when Checkout is updated' do
        expect(order.reload.payments.first.state).to eq 'completed'
      end

    end

    context 'with invalid credentials' do
      let(:gateway) { create(:vzero_gateway, merchant_id: 'invalid_id') }

      it 'raises Braintree error' do
        expect { gateway.client_token }.to raise_error('Braintree::AuthenticationError')
      end

    end
  end
end