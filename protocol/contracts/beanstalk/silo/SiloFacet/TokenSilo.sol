/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import "./Silo.sol";
import {IERC1155} from "~/interfaces/IERC1155.sol";

/**
 * @title TokenSilo
 * @author Publius, Brean
 * @notice This contract contains functions for depositing, withdrawing and 
 * claiming whitelisted Silo tokens.
 *
 * @dev WONTFIX: There is asymmetry in the structure of deposit / withdrawal functions.
 * Since the withdraw + claim step is being removed in Silo V3 in the coming
 * months, we'll leave these asymmetries present for now.
 *
 * - LibTokenSilo offers `incrementTotalDeposited` and `decrementTotalDeposited`
 *   but these operations are performed directly for withdrawals.
 * - "Removing a Deposit" only removes from the `account`; the total amount
 *   deposited in the Silo is decremented during withdrawal, _after_ a Withdrawal
 *   is created. See "Finish Removal".
 */
contract TokenSilo is Silo, IERC1155 {
    using SafeMath for uint256;
    using SafeCast for uint256;
    using LibSafeMath32 for uint32;

    

    /**
     * @notice Emitted when `account` adds a single Deposit to the Silo.
     *
     * There is no "AddDeposits" event because there is currently no operation in which Beanstalk
     * creates multiple Deposits in different stems:
     *
     *  - `deposit()` always places the user's deposit in the current `_season()`.
     *  - `convert()` collapses multiple deposits into a single Season to prevent loss of Stalk.
     *
     * @param account The account that added a Deposit.
     * @param token Address of the whitelisted ERC20 token that was deposited.
     * @param stem The stem index that this `amount` was added to.
     * @param amount Amount of `token` added to `stem`.
     * @param bdv The BDV associated with `amount` of `token` at the time of Deposit.
     */
    event AddDeposit(
        address indexed account,
        address indexed token,
        int96 grownStalkPerBdv,
        uint256 amount,
        uint256 bdv
    );

    /**
     * @notice Emitted when `account` removes a single Deposit from the Silo.
     * 
     * Occurs during `withdraw()` and `convert()` operations.
     * 
     * @param account The account that removed a Deposit.
     * @param token Address of the whitelisted ERC20 token that was removed.
     * @param stem The stem that this `amount` was removed from.
     * @param amount Amount of `token` removed from `stem`.
     * //add bdv here?
     */
    event RemoveDeposit(
        address indexed account,
        address indexed token,
        int96 grownStalkPerBdv,
        uint256 amount,
        uint256 bdv
    );

    /**
     * @notice Emitted when `account` removes multiple Deposits from the Silo.
     *
     * Occurs during `withdraw()` and `convert()` operations. 
     *
     * Gas optimization: emit 1 `RemoveDeposits` instead of N `RemoveDeposit` events.
     *
     * @param account The account that removed Deposits.
     * @param token Address of the whitelisted ERC20 token that was removed.
     * @param stems stems of Deposit to remove from.
     * @param amounts Amounts of `token` to remove from corresponding `stems`.
     * @param amount Sum of `amounts`.
     */
    event RemoveDeposits(
        address indexed account,
        address indexed token,
        int96[] grownStalkPerBdvs,
        uint256[] amounts,
        uint256 amount,
        uint256[] bdvs
    ); //add bdv[] here? in favor of array

    // note add/remove withdrawal(s) are removed as claiming is removed
    // FIXME: to discuss with subgraph team to update

    //////////////////////// UTILITIES ////////////////////////

    /**
     * @dev Convenience struct to simplify return value of {TokenSilo._withdrawDeposits()}.
     *
     * FIXME(naming): `tokensRemoved` -> `amountsRemoved`.
     */
    // struct AssetsRemoved {
    //     uint256 tokensRemoved;
    //     uint256 stalkRemoved;
    //     uint256 bdvRemoved;
    // }

    //////////////////////// GETTERS ////////////////////////

    /**
     * @notice Find the amount and BDV of `token` that `account` has Deposited in stem `stem`.
     * 
     * Returns a deposit tuple `(uint256 amount, uint256 bdv)`.
     *
     * @return amount The number of tokens contained in this Deposit.
     * @return bdv The BDV associated with this Deposit. See {FIXME(doc)}.
     */
    function getDeposit(
        address account,
        address token,
        int96 grownStalkPerBdv
    ) external view returns (uint256, uint256) {
        return LibTokenSilo.tokenDeposit(account, token, stem);
    }

    /**
     * @notice Get the total amount of `token` currently Deposited in the Silo across all users.
     */
    function getTotalDeposited(address token) external view returns (uint256) {
        return s.siloBalances[token].deposited;
    }

    /**
     * @notice Get the total amount of `token` currently Withdrawn from the Silo across all users.
     */
    function getTotalWithdrawn(address token) external view returns (uint256) {
        return s.siloBalances[token].withdrawn;
    }

    /**
     * @notice Get the Storage.SiloSettings for a whitelisted Silo token.
     *
     * Contains:
     *  - the BDV function selector
     *  - Stalk per BDV
     *  - stalkEarnedPerSeason
     *  - milestoneSeason
     *  - lastStem
     * 
     * @dev FIXME(naming) getTokenSettings ?
     */
    function tokenSettings(address token)
        external
        view
        returns (Storage.SiloSettings memory)
    {
        return s.ss[token];
    }

    //////////////////////// DEPOSIT ////////////////////////

    /**
     * @dev Handle deposit accounting.
     *
     * - {LibTokenSilo.deposit} calculates BDV, adds a Deposit to `account`, and
     *   increments the total amount Deposited.
     * - {LibSilo.mintStalk} mints the Stalk associated with
     *   the Deposit.
     * 
     * This step should enforce that new Deposits are placed into the current 
     * `LibTokenSilo.stemTipForToken(token)`.
     */
    function _deposit(
        address account,
        address token,
        uint256 amount
    ) internal {
        (uint256 stalk) = LibTokenSilo.deposit(
            account,
            token,
            LibTokenSilo.stemTipForToken(IERC20(token)),
            amount
        );

        LibSilo.mintStalk(account, stalk);
    }

    //////////////////////// WITHDRAW ////////////////////////

    /**
     * @dev Remove a single Deposit and create a single Withdrawal with its contents.
     */
    function _withdrawDeposit(
        address account,
        address token,
        int96 grownStalkPerBdv,
        uint256 amount
    ) internal {
        // Remove the Deposit from `account`.
        (uint256 stalkRemoved, ) = LibSilo._removeDepositFromAccount(
            account,
            address(token),
            grownStalkPerBdv,
            amount
        );
        
        // Add a Withdrawal, update totals, burn Stalk.
        _withdraw(
            account,
            address(token),
            amount,
            stalkRemoved
        );
    }

    /**
     * @dev Remove multiple Deposits and create a single Withdrawal with the
     * sum of their contents.
     *
     * Requirements:
     * - Each item in `stems` must have a corresponding item in `amounts`.
     */
    function _withdrawDeposits(
        address account,
        address token,
        int96[] calldata grownStalkPerBdvs,
        uint256[] calldata amounts
    ) internal returns (uint256) {
        require(
            stems.length == amounts.length,
            "Silo: Crates, amounts are diff lengths."
        );

        // Remove the Deposits from `account`.
        LibSilo.AssetsRemoved memory ar = LibSilo._removeDepositsFromAccount(
            account,
            token,
            stems,
            amounts
        );

        // Add a Withdrawal, update totals, burn Stalk.
        _withdraw(
            account,
            token,
            ar.tokensRemoved,
            ar.stalkRemoved
        );
        /** @dev we return ar.tokensremoved here, but not in _withdrawDeposit()
         *  to use in siloFacet.withdrawDeposits()
         */ 

        return ar.tokensRemoved;
    }

    /**
     * @dev Create a Withdrawal.
     *
     * Gas optimization: Completion of the Remove step (decrementing total
     * Deposited and burning Stalk) is performed here because there 
     */
    function _withdraw(
        address account,
        address token,
        uint256 amount,
        uint256 stalk
    ) private {
        LibTokenSilo.decrementTotalDeposited(token, amount); // Decrement total Deposited
        LibSilo.burnStalk(account, stalk); // Burn Stalk
    }


    /**
     * @dev Removes from a single Deposit, emits the RemoveDeposit event,
     * and returns the Stalk/BDV that were removed.
     *
     * Used in:
     * - {TokenSilo:_withdrawDeposit}
     * - {TokenSilo:_transferDeposit}
     */
    // TODO: rename should this be generalized?
    function removeDepositFromAccount(
        address account,
        address token,
        int96 grownStalkPerBdv,
        uint256 amount
    )
        private
        returns (
            uint256 stalkRemoved,
            uint256 bdvRemoved
        )
    {
        bdvRemoved = LibTokenSilo.removeDepositFromAccount(account, token, grownStalkPerBdv, amount);
        
        
        
        

        
        
        

        uint256 stalkReward = LibSilo.stalkReward(
                grownStalkPerBdv, //this is the index of when it was deposited
                LibTokenSilo.cumulativeGrownStalkPerBdv(IERC20(token)), //this is latest for this token
                bdvRemoved.toUint128()
            );
        


        //need to get amount of stalk earned by this deposit (index of now minus index of when deposited)
        stalkRemoved = bdvRemoved.mul(s.ss[token].stalkIssuedPerBdv).add(
            LibSilo.stalkReward(
                grownStalkPerBdv, //this is the index of when it was deposited
                LibTokenSilo.cumulativeGrownStalkPerBdv(IERC20(token)), //this is latest for this token
                bdvRemoved.toUint128()
            )
        );
        

        // "removing" a deposit is equivalent to "burning" an ERC1155 token.
        uint256 depositData = uint256(LibBytes.packAddressAndCumulativeStalkPerBDV(token, grownStalkPerBdv));
        emit TransferSingle(msg.sender, account, address(0), depositData, amount);
        emit RemoveDeposit(account, token, grownStalkPerBdv, amount, bdvRemoved);
    }

    /**
     * @dev Removes from multiple Deposits, emits the RemoveDeposits
     * event, and returns the Stalk/BDV that were removed.
     * 
     * Used in:
     * - {TokenSilo:_withdrawDeposits}
     * - {SiloFacet:enrootDeposits}
     */
    function removeDepositsFromAccount(
        address account,
        address token,
        int96[] calldata grownStalkPerBdvs,
        uint256[] calldata amounts
    ) internal returns (AssetsRemoved memory ar) {
        
        //make bdv array and add here?
        uint256[] memory bdvsRemoved = new uint256[](grownStalkPerBdvs.length);
        uint256[] memory removedDepositIDs = new uint256[](grownStalkPerBdvs.length);
        for (uint256 i; i < grownStalkPerBdvs.length; ++i) {
            uint256 crateBdv = LibTokenSilo.removeDepositFromAccount(
                account,
                token,
                grownStalkPerBdvs[i],
                amounts[i]
            );
            bdvsRemoved[i] = crateBdv;
            removedDepositIDs[i] = uint256(LibBytes.packAddressAndCumulativeStalkPerBDV(token, grownStalkPerBdvs[i]));
            ar.bdvRemoved = ar.bdvRemoved.add(crateBdv);
            ar.tokensRemoved = ar.tokensRemoved.add(amounts[i]);
            
            ar.stalkRemoved = ar.stalkRemoved.add(
                LibSilo.stalkReward(
                    grownStalkPerBdvs[i],
                    LibTokenSilo.cumulativeGrownStalkPerBdv(IERC20(token)),
                    crateBdv.toUint128()
                )
            );
            
        }
        
        ar.stalkRemoved = ar.stalkRemoved.add(
            ar.bdvRemoved.mul(s.ss[token].stalkIssuedPerBdv)
        );
        

        // "removing" deposits is equivalent to "burning" a batch of ERC1155 tokens.
        emit TransferBatch(msg.sender, account, address(0), removedDepositIDs, amounts);
        emit RemoveDeposits(account, token, grownStalkPerBdvs, amounts, ar.tokensRemoved, bdvsRemoved);
    }

    //////////////////////// TRANSFER ////////////////////////

    /**
     * @dev Removes `amount` of a single Deposit from `sender` and transfers
     * it to `recipient`. No Stalk are burned, and the total amount of
     * Deposited `token` in the Silo doesn't change. 
     */
    function _transferDeposit(
        address sender,
        address recipient,
        address token,
        int96 grownStalkPerBdv,
        uint256 amount
    ) internal returns (uint256) {
        (uint256 stalk, uint256 bdv) = LibSilo._removeDepositFromAccount(
            sender,
            token,
            grownStalkPerBdv,
            amount
        );
        LibTokenSilo.addDepositToAccount(recipient, token, grownStalkPerBdv, amount, bdv);
        LibSilo.transferStalk(sender, recipient, stalk);
        return bdv;
    }

    /**
     * @dev Removes `amounts` of multiple Deposits from `sender` and transfers
     * them to `recipient`. No Stalk are burned, and the total amount of
     * Deposited `token` in the Silo doesn't change. 
     */
    function _transferDeposits(
        address sender,
        address recipient,
        address token,
        int96[] calldata grownStalkPerBdvs,
        uint256[] calldata amounts
    ) internal returns (uint256[] memory) {
        require(
            stems.length == amounts.length,
            "Silo: Crates, amounts are diff lengths."
        );

        AssetsRemoved memory ar;
        uint256[] memory bdvs = new uint256[](grownStalkPerBdvs.length);
        uint256[] memory removedDepositIDs = new uint256[](grownStalkPerBdvs.length);

        // Similar to {removeDepositsFromAccount}, however the Deposit is also 
        // added to the recipient's account during each iteration.
        for (uint256 i; i < grownStalkPerBdvs.length; ++i) {
            uint256 depositID = uint256(LibBytes.packAddressAndCumulativeStalkPerBDV(token, grownStalkPerBdvs[i]));
            uint256 crateBdv = LibTokenSilo.removeDepositFromAccount(
                sender,
                token,
                stems[i],
                amounts[i]
            );
            LibTokenSilo.addDepositToAccount(
                recipient,
                token,
                stems[i],
                amounts[i],
                crateBdv
            );
            ar.bdvRemoved = ar.bdvRemoved.add(crateBdv);
            ar.tokensRemoved = ar.tokensRemoved.add(amounts[i]);
            ar.stalkRemoved = ar.stalkRemoved.add(
                LibSilo.stalkReward(
                    stems[i],
                    LibTokenSilo.stemTipForToken(IERC20(token)),
                    crateBdv.toUint128()
                )
            );
            bdvs[i] = crateBdv;
            removedDepositIDs[i] = depositID;

        }

        ar.stalkRemoved = ar.stalkRemoved.add(
            ar.bdvRemoved.mul(s.ss[token].stalkIssuedPerBdv)
        );

        //  "removing" a deposit is equivalent to "burning" a ERC1155 token
        // i.e, send to 0 sender
        emit TransferBatch(msg.sender, sender, address(0), removedDepositIDs, amounts);
        emit RemoveDeposits(sender, token, grownStalkPerBdvs, amounts, ar.tokensRemoved, bdvs);

        // Transfer all the Stalk
        LibSilo.transferStalk(
            sender,
            recipient,
            ar.stalkRemoved
        );

        return bdvs;
    }

        
    function _approveDeposit(address account, address spender, address token, uint256 amount) internal {
        s.a[account].depositAllowances[spender][token] = amount;
        emit DepositApproval(account, spender, token, amount);
    }
    
    //////////////////////// ERC1155 ////////////////////////

    function setApprovalForAll(
        address spender, 
        bool approved
    ) external override {
        s.a[msg.sender].isApprovedForAll[spender] = approved;
        emit ApprovalForAll(msg.sender, spender, approved);
    }

    function isApprovedForAll(
        address _owner, 
        address _operator
    ) external view override returns (bool) {
        return s.a[_owner].isApprovedForAll[_operator];
    }

    function balanceOf(
        address account, 
        uint256 depositId
    ) external view override returns (uint256 amount) {
        return s.a[account].deposits[bytes32(depositId)].amount;
    }

    function balanceOfBatch(
        address[] calldata accounts, 
        uint256[] calldata depositIds
    ) external view override returns (uint256[] memory) {
        require(
            accounts.length == depositIds.length, 
            "ERC1155: ids and amounts length mismatch"
        );
        uint256[] memory balances = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            balances[i] = s.a[accounts[i]].deposits[bytes32(depositIds[i])].amount;
        }
        return balances;
    }

    function safeTransferFrom(
        address _from, 
        address _to, 
        uint256 _id, 
        uint256 _value, 
        bytes calldata _data
    ) external virtual override {}

    function safeBatchTransferFrom(
        address _from,
        address _to,
        uint256[] calldata _ids,
        uint256[] calldata _values,
        bytes calldata _data
    ) external virtual override {}

    function getDepositId(
        address token, 
        int96 grownStalkPerBDV
    ) external pure returns (bytes32) {
        return LibBytes.packAddressAndCumulativeStalkPerBDV(token, grownStalkPerBDV);
    }
}
