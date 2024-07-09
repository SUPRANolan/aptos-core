spec supra_framework::delegation_pool {
    /// <high-level-req>
    /// No.: 1
    /// Requirement: Every DelegationPool has only one corresponding StakePool stored at the same address.
    /// Criticality: Critical
    /// Implementation: Upon calling the initialize_delegation_pool function, a resource account is created from the
    /// "owner" signer to host the delegation pool resource and own the underlying stake pool.
    /// Enforcement: Audited that the address of StakePool equals address of DelegationPool and the data invariant on the DelegationPool.
    ///
    /// No.: 2
    /// Requirement: The signer capability within the delegation pool has an address equal to the address of the
    /// delegation pool.
    /// Criticality: Critical
    /// Implementation: The initialize_delegation_pool function moves the DelegationPool resource to the address
    /// associated with stake_pool_signer, which also possesses the signer capability.
    /// Enforcement: Audited that the address of signer cap equals address of DelegationPool.
    ///
    /// No.: 3
    /// Requirement: A delegator holds shares exclusively in one inactive shares pool, which could either be an already
    /// inactive pool or the pending_inactive pool.
    /// Criticality: High
    /// Implementation: The get_stake function returns the inactive stake owned by a delegator and checks which
    /// state the shares are in via the get_pending_withdrawal function.
    /// Enforcement: Audited that either inactive or pending_inactive stake after invoking the get_stake function is
    /// zero and both are never non-zero.
    ///
    /// No.: 4
    /// Requirement: The specific pool in which the delegator possesses inactive shares becomes designated as the
    /// pending withdrawal pool for that delegator.
    /// Criticality: Medium
    /// Implementation: The get_pending_withdrawal function checks if any pending withdrawal exists for a delegate
    /// address and if there is neither inactive nor pending_inactive stake, the pending_withdrawal_exists returns
    /// false.
    /// Enforcement: This has been audited.
    ///
    /// No.: 5
    /// Requirement: The existence of a pending withdrawal implies that it is associated with a pool where the
    /// delegator possesses inactive shares.
    /// Criticality: Medium
    /// Implementation: In the get_pending_withdrawal function, if withdrawal_exists is true, the function returns
    /// true and a non-zero amount
    /// Enforcement: get_pending_withdrawal has been audited.
    ///
    /// No.: 6
    /// Requirement: An inactive shares pool should have coins allocated to it; otherwise, it should become deleted.
    /// Criticality: Medium
    /// Implementation: The redeem_inactive_shares function has a check that destroys the inactive shares pool,
    /// given that it is empty.
    /// Enforcement: shares pools have been audited.
    ///
    /// No.: 7
    /// Requirement: The index of the pending withdrawal will not exceed the current OLC on DelegationPool.
    /// Criticality: High
    /// Implementation: The get_pending_withdrawal function has a check which ensures that withdrawal_olc.index <
    /// pool.observed_lockup_cycle.index.
    /// Enforcement: This has been audited.
    ///
    /// No.: 8
    /// Requirement: Slashing is not possible for inactive stakes.
    /// Criticality: Critical
    /// Implementation: The number of inactive staked coins must be greater than or equal to the
    /// total_coins_inactive of the pool.
    /// Enforcement: This has been audited.
    ///
    /// No.: 9
    /// Requirement: The delegator's active or pending inactive stake will always meet or exceed the minimum allowed
    /// value.
    /// Criticality: Medium
    /// Implementation: The add_stake, unlock and reactivate_stake functions ensure the active_shares or
    /// pending_inactive_shares balance for the delegator is greater than or equal to the MIN_COINS_ON_SHARES_POOL
    /// value.
    /// Enforcement: Audited the comparison of active_shares or inactive_shares balance for the delegator with the
    /// MIN_COINS_ON_SHARES_POOL value.
    ///
    /// No.: 10
    /// Requirement: The delegation pool exists at a given address.
    /// Criticality: Low
    /// Implementation: Functions that operate on the DelegationPool abort if there is no DelegationPool struct
    /// under the given pool_address.
    /// Enforcement: Audited that there is no DelegationPool structure assigned to the pool_address given as a
    /// parameter.
    ///
    /// No.: 11
    /// Requirement: The initialization of the delegation pool is contingent upon enabling the delegation pools
    /// feature.
    /// Criticality: Critical
    /// Implementation: The initialize_delegation_pool function should proceed if the DELEGATION_POOLS feature is
    /// enabled.
    /// Enforcement: This has been audited.
    /// </high-level-req>
    ///
    spec module {
        // TODO: verification disabled until this module is specified.
        pragma verify=false;
    }

    spec initialize_delegation_pool {
        pragma verify = true;
        include stake::ResourceRequirement;
        /// [high-level-req-1]
        let owner_address = signer::address_of(owner);
        let seed = spec_create_resource_account_seed(delegation_pool_creation_seed);
        let resource_address = account::spec_create_resource_address(owner_address, seed);
        ensures exists<DelegationPoolOwnership>(TRACE(owner_address));
        // ensures exists<DelegationPool>(resource_address);
        // ensures exists<stake::StakePool>(TRACE(resource_address));
        /// [high-level-req-2]
        let signer_address = global<DelegationPool>(resource_address).stake_pool_signer_cap.account;
        let pool_address_in_owner = global<DelegationPoolOwnership>(TRACE(owner_address)).pool_address;
        // ensures TRACE(signer_address) == TRACE(pool_address_in_owner);
    }

    spec get_used_voting_power {
        pragma verify = true;
        pragma opaque;
        let votes = governance_records.votes;
        let key = VotingRecordKey {
            voter,
            proposal_id,
        };
        ensures smart_table::spec_contains(votes, key) ==> result == smart_table::spec_get(votes, key)
        && (!smart_table::spec_contains(votes, key)) ==> result == 0;
    }

    spec create_resource_account_seed {
        pragma verify = true;
        ensures result == spec_create_resource_account_seed(delegation_pool_creation_seed);
    }

    spec fun spec_create_resource_account_seed(
        delegation_pool_creation_seed: vector<u8>,
    ): vector<u8> {
        let seed = concat(MODULE_SALT, delegation_pool_creation_seed);
        seed
    }

    spec enable_partial_governance_voting {
        let delegation_pool = borrow_global<DelegationPool>(pool_address);
    }

    spec amount_to_shares_to_redeem {
        /// return pool_u64::shares(shares_pool, shareholder) if coins_amount >= pool_u64::balance(shares_pool, shareholder)
        /// else return pool_u64::amount_to_shares(shares_pool, coins_amount)
        pragma verify = true;
        // pragma opaque;
        // ensures coins_amount >= pool_u64::balance(shares_pool, shareholder) ==>
        //     result == pool_u64::shares(shares_pool, shareholder);
        // ensures coins_amount < pool_u64::balance(shares_pool, shareholder) ==>
        //     result == pool_u64::amount_to_shares(shares_pool, coins_amount);
    }

    spec coins_to_redeem_to_ensure_min_stake {
        pragma verify = true;
        // let src_balance = pool_u64::balance(src_shares_pool, shareholder);
        // let redeemed_coins = pool_u64::shares_to_amount(
        //     src_shares_pool,
        //     amount_to_shares_to_redeem(src_shares_pool, shareholder, amount)
        // );
        // ensures src_balance - redeemed_coins < MIN_COINS_ON_SHARES_POOL ==> result == src_balance;
    }

    spec coins_to_transfer_to_ensure_min_stake {

    }

    spec update_governanace_records_for_redeem_pending_inactive_shares {

    }
}
