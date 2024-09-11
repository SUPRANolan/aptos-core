spec supra_framework::genesis {
    spec module {
        // We are not proving each genesis step individually. Instead, we construct
        // and prove `initialize_for_verification` which is a "#[verify_only]" function that
        // simulates the genesis encoding process in `vm-genesis` (written in Rust).
        // So, we turn off the verification at the module level, but turn it on for
        // the verification-only function `initialize_for_verification`.
        include InitalizeRequires;
    }

    spec set_genesis_end {
        pragma delegate_invariants_to_caller;
        // property 4: An initial set of validators should exist before the end of genesis.
        /// [high-level-req-4]
        requires len(global<stake::ValidatorSet>(@supra_framework).active_validators) >= 1;
        // property 5: The end of genesis should be marked on chain.
        /// [high-level-req-5]
        let addr = std::signer::address_of(supra_framework);
        aborts_if addr != @supra_framework;
        aborts_if exists<chain_status::GenesisEndMarker>(@supra_framework);
        ensures global<chain_status::GenesisEndMarker>(@supra_framework) == chain_status::GenesisEndMarker {};
    }

    spec create_pbo_delegation_pools {
        pragma verify = false;
    }

    spec initialize_for_verification {
        pragma verify = true;
    }
}
