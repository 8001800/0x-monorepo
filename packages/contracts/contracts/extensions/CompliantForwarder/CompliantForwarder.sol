/*

  Copyright 2018 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity 0.4.24;
pragma experimental ABIEncoderV2;

import "../../protocol/Exchange/interfaces/IExchange.sol";
import "../../tokens/ERC721Token/IERC721Token.sol";
import "../../utils/LibBytes/LibBytes.sol";
import "../../utils/ExchangeSelectors/ExchangeSelectors.sol";

contract CompliantForwarder is ExchangeSelectors{

    using LibBytes for bytes;

    IExchange internal EXCHANGE;
    IERC721Token internal COMPLIANCE_TOKEN;

    event ValidatedAddresses (
        address[] addresses
    );

    constructor(address exchange, address complianceToken)
        public
    {
        EXCHANGE = IExchange(exchange);
        COMPLIANCE_TOKEN = IERC721Token(complianceToken);
    }

    function executeTransaction(
        uint256 salt,
        address signerAddress,
        bytes signedExchangeTransaction,
        bytes signature
    ) 
        external
    {
        // Addresses that are validated below.
        address[] memory validatedAddresses;

        /**
         * Do not add variables after this point.
         * The assembly block may overwrite their values.
         */

        // Validate addresses
        assembly {
            function exchangeCalldataload(offset) -> value {
                // exchangeTxPtr at global level
                // 0x20 for length offset into exchange TX
                // 0x4 for function selector in exhcange TX
                let exchangeTxPtr := calldataload(0x44)
                let exchangeOffset := add(exchangeTxPtr, add(0x24, offset))
                value := calldataload(exchangeOffset)
            }

            function loadExchangeData(offset) -> value {
                value := exchangeCalldataload(add(offset, 0x4))
            }

            // Adds address to validate
            function addAddressToValidate(addressToValidate) {
                // Compute `addressesToValidate` memory location
                let addressesToValidate_ := mload(0x40)
                let nAddressesToValidate_ := mload(addressesToValidate_)

                // Increment length
                nAddressesToValidate_ := add(mload(addressesToValidate_), 1)
                mstore(addressesToValidate_, nAddressesToValidate_)

                // Append address to validate
                let offset := mul(32, nAddressesToValidate_)
                mstore(add(addressesToValidate_, offset), addressToValidate)
            }

            function appendMakerAddressFromOrder(orderParamIndex) {
                let orderPtr := loadExchangeData(0)
                let makerAddress := loadExchangeData(orderPtr)
                addAddressToValidate(makerAddress)
            }

            function appendMakerAddressesFromOrderSet(orderSetParamIndex) {
                let orderSetPtr := loadExchangeData(0)
                let orderSetLength := loadExchangeData(orderSetPtr)
                let orderSetElementPtr := add(orderSetPtr, 0x20)
                let orderSetElementEndPtr := add(orderSetElementPtr, mul(orderSetLength, 0x20))
                for {let orderPtrOffset := orderSetElementPtr} lt(orderPtrOffset, orderSetElementEndPtr) {orderPtrOffset := add(orderPtrOffset, 0x20)} {
                    let orderPtr := loadExchangeData(orderPtrOffset)
                    let makerAddress := loadExchangeData(add(orderPtr, orderSetElementPtr))
                    addAddressToValidate(makerAddress)
                }
            }

            // Extract addresses to validate
            let selector := and(
                exchangeCalldataload(0),
                0xffffffff00000000000000000000000000000000000000000000000000000000
            )
            switch selector
            case 0x297bb70b00000000000000000000000000000000000000000000000000000000 /* batchFillOrders */
            {
                appendMakerAddressesFromOrderSet(0)
                addAddressToValidate(signerAddress)
            }
            case 0x3c28d86100000000000000000000000000000000000000000000000000000000 /* matchOrders */
            {
               // appendMakerAddressFromOrder(0)
               //// appendMakerAddressFromOrder(1)
               // addAddressToValidate(signerAddress)
            }
            case 0xb4be83d500000000000000000000000000000000000000000000000000000000 /* fillOrder */
            {
                appendMakerAddressFromOrder(0)
                addAddressToValidate(signerAddress)
            }
            case 0xd46b02c300000000000000000000000000000000000000000000000000000000 /* cancelOrder */ {}
            default {
                revert(0, 100)
            }

            // Load addresses to validate from memory
            let addressesToValidate := mload(0x40)
            let addressesToValidateLength := mload(addressesToValidate)
            let addressesToValidateElementPtr := add(addressesToValidate, 0x20)
            let addressesToValidateElementEndPtr := add(addressesToValidateElementPtr, mul(addressesToValidateLength, 0x20))

            // Record new free memory pointer to after `addressesToValidate` array
            // This is to avoid corruption when making calls in the loop below.
            let freeMemPtr := addressesToValidateElementEndPtr
            mstore(0x40, freeMemPtr)

            // Validate addresses
            let complianceTokenAddress := sload(COMPLIANCE_TOKEN_slot)
            
            for {let addressToValidate := addressesToValidateElementPtr} lt(addressToValidate, addressesToValidateElementEndPtr) {addressToValidate := add(addressToValidate, 0x20)} {
                // Construct calldata for `COMPLIANCE_TOKEN.balanceOf`
                mstore(freeMemPtr, 0x70a0823100000000000000000000000000000000000000000000000000000000)
                mstore(add(4, freeMemPtr), mload(addressToValidate))
               
                // call `COMPLIANCE_TOKEN.balanceOf`
                let success := call(
                    gas,                                    // forward all gas
                    complianceTokenAddress,                 // call address of asset proxy
                    0,                                      // don't send any ETH
                    freeMemPtr,                             // pointer to start of input
                    0x24,                                   // length of input (one padded address) 
                    freeMemPtr,                             // write output to next free memory offset
                    0x20                                    // reserve space for return balance (0x20 bytes)
                )
                if eq(success, 0) {
                    // @TODO Revert with `Error("BALANCE_CHECK_FAILED")`
                    revert(0, 100)
                }

                // Revert if balance not held
                let addressBalance := mload(freeMemPtr)
                if eq(addressBalance, 0) {
                    // Revert with `Error("AT_LEAST_ONE_ADDRESS_HAS_ZERO_BALANCE")`
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(32, 0x0000002000000000000000000000000000000000000000000000000000000000)
                    mstore(64, 0x0000002541545f4c454153545f4f4e455f414444524553535f4841535f5a4552)
                    mstore(96, 0x4f5f42414c414e43450000000000000000000000000000000000000000000000)
                    revert(0, 109)
                }
            }

            // Record validated addresses
            validatedAddresses := addressesToValidate
        }

        emit ValidatedAddresses(validatedAddresses);
        
        // All entities are verified. Execute fillOrder.
        EXCHANGE.executeTransaction(
            salt,
            signerAddress,
            signedExchangeTransaction,
            signature
        );
    }
}