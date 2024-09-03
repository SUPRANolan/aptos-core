///
/// AptosGovernance represents the on-chain governance of the Aptos network. Voting power is calculated based on the
/// current epoch's voting power of the proposer or voter's backing stake pool. In addition, for it to count,
/// the stake pool's lockup needs to be at least as long as the proposal's duration.
///
/// It provides the following flow:
/// 1. Proposers can create a proposal by calling AptosGovernance::create_proposal. The proposer's backing stake pool
/// needs to have the minimum proposer stake required. Off-chain components can subscribe to CreateProposalEvent to
/// track proposal creation and proposal ids.
/// 2. Voters can vote on a proposal. Their voting power is derived from the backing stake pool. A stake pool can vote
/// on a proposal multiple times as long as the total voting power of these votes doesn't exceed its total voting power.
module supra_framework::supra_governance {
    use std::error;
    use std::signer;
    use std::string::{Self, String, utf8};
    use std::vector;
    use std::features;

    use aptos_std::simple_map::{Self, SimpleMap};

    use supra_framework::account::{Self, SignerCapability, create_signer_with_capability};
    use supra_framework::event::{Self, EventHandle};
    use supra_framework::governance_proposal::{Self, GovernanceProposal};
    use supra_framework::system_addresses;
    use supra_framework::supra_coin;
    use supra_framework::consensus_config;
    use supra_framework::randomness_config;
    use supra_framework::reconfiguration_with_dkg;
    use supra_framework::timestamp;
    use supra_framework::multisig_voting;

    /// Proposal is not ready to be resolved. Waiting on time or votes
    const EPROPOSAL_NOT_RESOLVABLE_YET: u64 = 6;
    /// The proposal has not been resolved yet
    const EPROPOSAL_NOT_RESOLVED_YET: u64 = 8;
    /// Metadata location cannot be longer than 256 chars
    const EMETADATA_LOCATION_TOO_LONG: u64 = 9;
    /// Metadata hash cannot be longer than 256 chars
    const EMETADATA_HASH_TOO_LONG: u64 = 10;
    /// Account is not authorized to call this function.
    const EUNAUTHORIZED: u64 = 11;
    /// The account does not have permission to propose or vote
    const EACCOUNT_NOT_AUTHORIZED: u64 = 15;
    /// Proposal is expired
    const EPROPOSAL_IS_EXPIRE: u64 = 16;
    /// Threshold should not exceeds voters
    const ETHRESHOLD_EXCEEDS_VOTERS: u64 = 17;
    /// Threshold value must be greater than 1
    const ETHRESHOLD_MUST_BE_GREATER_THAN_ONE: u64 = 18;

    /// This matches the same enum const in voting. We have to duplicate it as Move doesn't have support for enums yet.
    const PROPOSAL_STATE_SUCCEEDED: u64 = 1;

    /// Proposal metadata attribute keys.
    const METADATA_LOCATION_KEY: vector<u8> = b"metadata_location";
    const METADATA_HASH_KEY: vector<u8> = b"metadata_hash";

    /// Store the SignerCapabilities of accounts under the on-chain governance's control.
    struct GovernanceResponsbility has key {
        signer_caps: SimpleMap<address, SignerCapability>,
    }

    /// Used to track which execution script hashes have been approved by governance.
    /// This is required to bypass cases where the execution scripts exceed the size limit imposed by mempool.
    struct ApprovedExecutionHashes has key {
        hashes: SimpleMap<u64, vector<u8>>,
    }

    /// Configurations of the SupraGovernance, set during Genesis and can be updated by the same process offered
    /// by this SupraGovernance module.
    struct SupraGovernanceConfig has key {
        voting_duration_secs: u64,
        min_voting_threshold: u64,
        voters: vector<address>,
    }

    /// Events generated by interactions with the SupraGovernance module.
    struct SupraGovernanceEvents has key {
        create_proposal_events: EventHandle<SupraCreateProposalEvent>,
        update_config_events: EventHandle<SupraUpdateConfigEvent>,
        vote_events: EventHandle<SupraVoteEvent>,
    }

    /// Event emitted when a proposal is created.
    struct SupraCreateProposalEvent has drop, store {
        proposer: address,
        proposal_id: u64,
        execution_hash: vector<u8>,
        proposal_metadata: SimpleMap<String, vector<u8>>,
    }

    /// Event emitted when the governance configs are updated.
    struct SupraUpdateConfigEvent has drop, store {
        voting_duration_secs: u64,
        min_voting_threshold: u64,
        voters: vector<address>,
    }

    /// Event emitted when there's a vote on a proposa;
    struct SupraVoteEvent has drop, store {
        proposal_id: u64,
        voter: address,
        should_pass: bool,
    }

    #[event]
    /// Event emitted when a proposal is created.
    struct SupraCreateProposal has drop, store {
        proposer: address,
        proposal_id: u64,
        execution_hash: vector<u8>,
        proposal_metadata: SimpleMap<String, vector<u8>>,
    }

    #[event]
    /// Event emitted when there's a vote on a proposa;
    struct SupraVote has drop, store {
        proposal_id: u64,
        voter: address,
        should_pass: bool,
    }

    #[event]
    /// Event emitted when the governance configs are updated.
    struct SupraUpdateConfig has drop, store {
        voting_duration_secs: u64,
        min_voting_threshold: u64,
        voters: vector<address>,
    }

    /// Can be called during genesis or by the governance itself.
    /// Stores the signer capability for a given address.
    public fun store_signer_cap(
        supra_framework: &signer,
        signer_address: address,
        signer_cap: SignerCapability,
    ) acquires GovernanceResponsbility {
        system_addresses::assert_supra_framework(supra_framework);
        system_addresses::assert_framework_reserved(signer_address);

        if (!exists<GovernanceResponsbility>(@supra_framework)) {
            move_to(
                supra_framework,
                GovernanceResponsbility { signer_caps: simple_map::create<address, SignerCapability>() }
            );
        };

        let signer_caps = &mut borrow_global_mut<GovernanceResponsbility>(@supra_framework).signer_caps;
        simple_map::add(signer_caps, signer_address, signer_cap);
    }

    /// Initializes the state for Aptos Governance. Can only be called during Genesis with a signer
    /// for the supra_framework (0x1) account.
    /// This function is private because it's called directly from the vm.
    fun initialize(
        supra_framework: &signer,
        voting_duration_secs: u64,
        min_voting_threshold: u64,
        voters: vector<address>,
    ) {
        multisig_voting::register<GovernanceProposal>(supra_framework);

        assert!(vector::length(&voters) >= min_voting_threshold && min_voting_threshold > vector::length(&voters) / 2, error::invalid_argument(ETHRESHOLD_EXCEEDS_VOTERS));
        assert!(min_voting_threshold > 1, error::invalid_argument(ETHRESHOLD_MUST_BE_GREATER_THAN_ONE));

        move_to(supra_framework, SupraGovernanceConfig {
            voting_duration_secs,
            min_voting_threshold,
            voters,
        });
        move_to(supra_framework, SupraGovernanceEvents {
            create_proposal_events: account::new_event_handle<SupraCreateProposalEvent>(supra_framework),
            update_config_events: account::new_event_handle<SupraUpdateConfigEvent>(supra_framework),
            vote_events: account::new_event_handle<SupraVoteEvent>(supra_framework),
        });
        move_to(supra_framework, ApprovedExecutionHashes {
            hashes: simple_map::create<u64, vector<u8>>(),
        })
    }

    /// Update the governance configurations. This can only be called as part of resolving a proposal in this same
    /// AptosGovernance.
    public fun update_supra_governance_config(
        supra_framework: &signer,
        voting_duration_secs: u64,
        min_voting_threshold: u64,
        voters: vector<address>,
    ) acquires SupraGovernanceConfig, SupraGovernanceEvents {
        system_addresses::assert_supra_framework(supra_framework);

        assert!(vector::length(&voters) >= min_voting_threshold && min_voting_threshold > vector::length(&voters) / 2, error::invalid_argument(ETHRESHOLD_EXCEEDS_VOTERS));
        assert!(min_voting_threshold > 1, error::invalid_argument(ETHRESHOLD_MUST_BE_GREATER_THAN_ONE));

        let supra_governance_config = borrow_global_mut<SupraGovernanceConfig>(@supra_framework);
        supra_governance_config.voting_duration_secs = voting_duration_secs;
        supra_governance_config.min_voting_threshold = min_voting_threshold;
        supra_governance_config.voters = voters;

        if (std::features::module_event_migration_enabled()) {
            event::emit(
                SupraUpdateConfig {
                    min_voting_threshold,
                    voting_duration_secs,
                    voters,
                },
            )
        };
        let events = borrow_global_mut<SupraGovernanceEvents>(@supra_framework);
        event::emit_event<SupraUpdateConfigEvent>(
            &mut events.update_config_events,
            SupraUpdateConfigEvent {
                min_voting_threshold,
                voting_duration_secs,
                voters,
            },
        );
    }

    #[view]
    public fun get_voting_duration_secs(): u64 acquires SupraGovernanceConfig {
        borrow_global<SupraGovernanceConfig>(@supra_framework).voting_duration_secs
    }

    #[view]
    public fun get_min_voting_threshold(): u64 acquires SupraGovernanceConfig {
        borrow_global<SupraGovernanceConfig>(@supra_framework).min_voting_threshold
    }

    #[view]
    public fun get_voters_list(): vector<address> acquires SupraGovernanceConfig {
        borrow_global<SupraGovernanceConfig>(@supra_framework).voters
    }

    /// Create a single-step proposal with the backing `stake_pool`.
    /// @param execution_hash Required. This is the hash of the resolution script. When the proposal is resolved,
    /// only the exact script with matching hash can be successfully executed.
    public entry fun supra_create_proposal(
        proposer: &signer,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>,
    ) acquires SupraGovernanceConfig, SupraGovernanceEvents {
        supra_create_proposal_v2(proposer, execution_hash, metadata_location, metadata_hash, false);
    }

    /// Create a single-step or multi-step proposal with the backing `stake_pool`.
    /// @param execution_hash Required. This is the hash of the resolution script. When the proposal is resolved,
    /// only the exact script with matching hash can be successfully executed.
    public entry fun supra_create_proposal_v2(
        proposer: &signer,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>,
        is_multi_step_proposal: bool,
    ) acquires SupraGovernanceConfig, SupraGovernanceEvents {
        supra_create_proposal_v2_impl(
            proposer,
            execution_hash,
            metadata_location,
            metadata_hash,
            is_multi_step_proposal
        );
    }

    /// Create a single-step or multi-step proposal with the backing `stake_pool`.
    /// @param execution_hash Required. This is the hash of the resolution script. When the proposal is resolved,
    /// only the exact script with matching hash can be successfully executed.
    /// Return proposal_id when a proposal is successfully created.
    public fun supra_create_proposal_v2_impl(
        proposer: &signer,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>,
        is_multi_step_proposal: bool,
    ): u64 acquires SupraGovernanceConfig, SupraGovernanceEvents {
        let proposer_address = signer::address_of(proposer);
        let supra_governance_config = borrow_global<SupraGovernanceConfig>(@supra_framework);

        assert!(vector::contains(&supra_governance_config.voters, &proposer_address), error::permission_denied(EACCOUNT_NOT_AUTHORIZED));

        let proposal_expiration = timestamp::now_seconds() + supra_governance_config.voting_duration_secs;

        // Create and validate proposal metadata.
        let proposal_metadata = create_proposal_metadata(metadata_location, metadata_hash);

        let proposal_id = multisig_voting::create_proposal_v2(
            proposer_address,
            @supra_framework,
            governance_proposal::create_proposal(),
            execution_hash,
            supra_governance_config.min_voting_threshold,
            supra_governance_config.voters,
            proposal_expiration,
            proposal_metadata,
            is_multi_step_proposal,
        );

        if (std::features::module_event_migration_enabled()) {
            event::emit(
                SupraCreateProposal {
                    proposal_id,
                    proposer: proposer_address,
                    execution_hash,
                    proposal_metadata,
                },
            );
        };
        let events = borrow_global_mut<SupraGovernanceEvents>(@supra_framework);
        event::emit_event<SupraCreateProposalEvent>(
            &mut events.create_proposal_events,
            SupraCreateProposalEvent {
                proposal_id,
                proposer: proposer_address,
                execution_hash,
                proposal_metadata,
            },
        );
        proposal_id
    }

    /// Vote on proposal with `proposal_id` and all voting power from `stake_pool`.
    public entry fun supra_vote(
        voter: &signer,
        proposal_id: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, SupraGovernanceEvents, SupraGovernanceConfig {
        supra_vote_internal(voter, proposal_id, should_pass);
    }

    /// Vote on proposal with `proposal_id` and specified voting_power from `stake_pool`.
    /// If voting_power is more than all the left voting power of `stake_pool`, use all the left voting power.
    /// If a stake pool has already voted on a proposal before partial governance voting is enabled, the stake pool
    /// cannot vote on the proposal even after partial governance voting is enabled.
    fun supra_vote_internal(
        voter: &signer,
        proposal_id: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, SupraGovernanceEvents, SupraGovernanceConfig {
        let voter_address = signer::address_of(voter);

        let supra_governance_config = borrow_global<SupraGovernanceConfig>(@supra_framework);
        assert!(vector::contains(&supra_governance_config.voters, &signer::address_of(voter)), error::permission_denied(EACCOUNT_NOT_AUTHORIZED));

        // The voter's stake needs to be locked up at least as long as the proposal's expiration.
        let proposal_expiration = multisig_voting::get_proposal_expiration_secs<GovernanceProposal>(
            @supra_framework,
            proposal_id
        );
        assert!(timestamp::now_seconds() <= proposal_expiration, error::invalid_argument(EPROPOSAL_IS_EXPIRE));

        multisig_voting::vote<GovernanceProposal>(
            voter,
            &governance_proposal::create_empty_proposal(),
            @supra_framework,
            proposal_id,
            should_pass,
        );

        if (std::features::module_event_migration_enabled()) {
            event::emit(
                SupraVote {
                    proposal_id,
                    voter: voter_address,
                    should_pass,
                },
            );
        };
        let events = borrow_global_mut<SupraGovernanceEvents>(@supra_framework);
        event::emit_event<SupraVoteEvent>(
            &mut events.vote_events,
            SupraVoteEvent {
                proposal_id,
                voter: voter_address,
                should_pass,
            },
        );

        let proposal_state = multisig_voting::get_proposal_state<GovernanceProposal>(@supra_framework, proposal_id);
        if (proposal_state == PROPOSAL_STATE_SUCCEEDED) {
            add_supra_approved_script_hash(proposal_id);
        }
    }

    public entry fun add_supra_approved_script_hash_script(proposal_id: u64) acquires ApprovedExecutionHashes {
        add_supra_approved_script_hash(proposal_id)
    }

    /// Add the execution script hash of a successful governance proposal to the approved list.
    /// This is needed to bypass the mempool transaction size limit for approved governance proposal transactions that
    /// are too large (e.g. module upgrades).
    public fun add_supra_approved_script_hash(proposal_id: u64) acquires ApprovedExecutionHashes {
        let approved_hashes = borrow_global_mut<ApprovedExecutionHashes>(@supra_framework);

        // Ensure the proposal can be resolved.
        let proposal_state = multisig_voting::get_proposal_state<GovernanceProposal>(@supra_framework, proposal_id);
        assert!(proposal_state == PROPOSAL_STATE_SUCCEEDED, error::invalid_argument(EPROPOSAL_NOT_RESOLVABLE_YET));

        let execution_hash = multisig_voting::get_execution_hash<GovernanceProposal>(@supra_framework, proposal_id);

        // If this is a multi-step proposal, the proposal id will already exist in the ApprovedExecutionHashes map.
        // We will update execution hash in ApprovedExecutionHashes to be the next_execution_hash.
        if (simple_map::contains_key(&approved_hashes.hashes, &proposal_id)) {
            let current_execution_hash = simple_map::borrow_mut(&mut approved_hashes.hashes, &proposal_id);
            *current_execution_hash = execution_hash;
        } else {
            simple_map::add(&mut approved_hashes.hashes, proposal_id, execution_hash);
        }
    }

    /// Resolve a successful single-step proposal. This would fail if the proposal is not successful (not enough votes or more no
    /// than yes).
    public fun supra_resolve(
        proposal_id: u64,
        signer_address: address
    ): signer acquires ApprovedExecutionHashes, GovernanceResponsbility {
        multisig_voting::resolve<GovernanceProposal>(@supra_framework, proposal_id);
        remove_supra_approved_hash(proposal_id);
        get_signer(signer_address)
    }

    /// Resolve a successful multi-step proposal. This would fail if the proposal is not successful.
    public fun resolve_supra_multi_step_proposal(
        proposal_id: u64,
        signer_address: address,
        next_execution_hash: vector<u8>
    ): signer acquires GovernanceResponsbility, ApprovedExecutionHashes {
        multisig_voting::resolve_proposal_v2<GovernanceProposal>(@supra_framework, proposal_id, next_execution_hash);
        // If the current step is the last step of this multi-step proposal,
        // we will remove the execution hash from the ApprovedExecutionHashes map.
        if (vector::length(&next_execution_hash) == 0) {
            remove_supra_approved_hash(proposal_id);
        } else {
            // If the current step is not the last step of this proposal,
            // we replace the current execution hash with the next execution hash
            // in the ApprovedExecutionHashes map.
            add_supra_approved_script_hash(proposal_id)
        };
        get_signer(signer_address)
    }

    /// Remove an approved proposal's execution script hash.
    public fun remove_supra_approved_hash(proposal_id: u64) acquires ApprovedExecutionHashes {
        assert!(
            multisig_voting::is_resolved<GovernanceProposal>(@supra_framework, proposal_id),
            error::invalid_argument(EPROPOSAL_NOT_RESOLVED_YET),
        );

        let approved_hashes = &mut borrow_global_mut<ApprovedExecutionHashes>(@supra_framework).hashes;
        if (simple_map::contains_key(approved_hashes, &proposal_id)) {
            simple_map::remove(approved_hashes, &proposal_id);
        };
    }

    /// Manually reconfigure. Called at the end of a governance txn that alters on-chain configs.
    ///
    /// WARNING: this function always ensures a reconfiguration starts, but when the reconfiguration finishes depends.
    /// - If feature `RECONFIGURE_WITH_DKG` is disabled, it finishes immediately.
    ///   - At the end of the calling transaction, we will be in a new epoch.
    /// - If feature `RECONFIGURE_WITH_DKG` is enabled, it starts DKG, and the new epoch will start in a block prologue after DKG finishes.
    ///
    /// This behavior affects when an update of an on-chain config (e.g. `ConsensusConfig`, `Features`) takes effect,
    /// since such updates are applied whenever we enter an new epoch.
    public entry fun reconfigure(supra_framework: &signer) {
        system_addresses::assert_supra_framework(supra_framework);
        if (consensus_config::validator_txn_enabled() && randomness_config::enabled()) {
            reconfiguration_with_dkg::try_start();
        } else {
            reconfiguration_with_dkg::finish(supra_framework);
        }
    }

    /// Change epoch immediately.
    /// If `RECONFIGURE_WITH_DKG` is enabled and we are in the middle of a DKG,
    /// stop waiting for DKG and enter the new epoch without randomness.
    ///
    /// WARNING: currently only used by tests. In most cases you should use `reconfigure()` instead.
    /// TODO: migrate these tests to be aware of async reconfiguration.
    public entry fun force_end_epoch(supra_framework: &signer) {
        system_addresses::assert_supra_framework(supra_framework);
        reconfiguration_with_dkg::finish(supra_framework);
    }

    /// `force_end_epoch()` equivalent but only called in testnet,
    /// where the core resources account exists and has been granted power to mint Aptos coins.
    public entry fun force_end_epoch_test_only(supra_framework: &signer) acquires GovernanceResponsbility {
        let core_signer = get_signer_testnet_only(supra_framework, @0x1);
        system_addresses::assert_supra_framework(&core_signer);
        reconfiguration_with_dkg::finish(&core_signer);
    }

    /// Update feature flags and also trigger reconfiguration.
    public fun toggle_features(supra_framework: &signer, enable: vector<u64>, disable: vector<u64>) {
        system_addresses::assert_supra_framework(supra_framework);
        features::change_feature_flags_for_next_epoch(supra_framework, enable, disable);
        reconfigure(supra_framework);
    }

    /// Only called in testnet where the core resources account exists and has been granted power to mint Aptos coins.
    public fun get_signer_testnet_only(
        core_resources: &signer, signer_address: address): signer acquires GovernanceResponsbility {
        system_addresses::assert_core_resource(core_resources);
        // Core resources account only has mint capability in tests/testnets.
        assert!(supra_coin::has_mint_capability(core_resources), error::unauthenticated(EUNAUTHORIZED));
        get_signer(signer_address)
    }

    /// Return a signer for making changes to 0x1 as part of on-chain governance proposal process.
    fun get_signer(signer_address: address): signer acquires GovernanceResponsbility {
        let governance_responsibility = borrow_global<GovernanceResponsbility>(@supra_framework);
        let signer_cap = simple_map::borrow(&governance_responsibility.signer_caps, &signer_address);
        create_signer_with_capability(signer_cap)
    }

    fun create_proposal_metadata(
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>
    ): SimpleMap<String, vector<u8>> {
        assert!(string::length(&utf8(metadata_location)) <= 256, error::invalid_argument(EMETADATA_LOCATION_TOO_LONG));
        assert!(string::length(&utf8(metadata_hash)) <= 256, error::invalid_argument(EMETADATA_HASH_TOO_LONG));

        let metadata = simple_map::create<String, vector<u8>>();
        simple_map::add(&mut metadata, utf8(METADATA_LOCATION_KEY), metadata_location);
        simple_map::add(&mut metadata, utf8(METADATA_HASH_KEY), metadata_hash);
        metadata
    }

    #[test_only]
    public entry fun supra_create_proposal_for_test(
        proposer: &signer,
        multi_step: bool,
    ) acquires SupraGovernanceConfig, SupraGovernanceEvents {
        let execution_hash = vector::empty<u8>();
        vector::push_back(&mut execution_hash, 1);
        if (multi_step) {
            supra_create_proposal_v2(
                proposer,
                execution_hash,
                b"",
                b"",
                true,
            );
        } else {
            supra_create_proposal(
                proposer,
                execution_hash,
                b"",
                b"",
            );
        };
    }

    #[test_only]
    public fun supra_resolve_proposal_for_test(
        proposal_id: u64,
        signer_address: address,
        multi_step: bool,
        finish_multi_step_execution: bool
    ): signer acquires ApprovedExecutionHashes, GovernanceResponsbility {
        if (multi_step) {
            let execution_hash = vector::empty<u8>();
            vector::push_back(&mut execution_hash, 1);

            if (finish_multi_step_execution) {
                resolve_supra_multi_step_proposal(proposal_id, signer_address, vector::empty<u8>())
            } else {
                resolve_supra_multi_step_proposal(proposal_id, signer_address, execution_hash)
            }
        } else {
            supra_resolve(proposal_id, signer_address)
        }
    }

    #[test_only]
    /// Force reconfigure. To be called at the end of a proposal that alters on-chain configs.
    public fun toggle_features_for_test(enable: vector<u64>, disable: vector<u64>) {
        toggle_features(&account::create_signer_for_test(@0x1), enable, disable);
    }

    #[test_only]
    public entry fun test_voting_generic(
        supra_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
        multi_step: bool,
        use_generic_resolve_function: bool,
    ) acquires ApprovedExecutionHashes, SupraGovernanceConfig, GovernanceResponsbility, SupraGovernanceEvents {
        let voters = vector[signer::address_of(proposer), signer::address_of(yes_voter), signer::address_of(no_voter)];
        supra_setup_voting(supra_framework, voters);

        let execution_hash = vector::empty<u8>();
        vector::push_back(&mut execution_hash, 1);

        supra_create_proposal_for_test(proposer, multi_step);

        supra_vote(proposer, 0, true);
        supra_vote(yes_voter, 0, true);
        supra_vote(no_voter, 0, false);

        supra_test_resolving_proposal_generic(supra_framework, use_generic_resolve_function, execution_hash);
    }

    #[test_only]
    public entry fun supra_test_resolving_proposal_generic(
        supra_framework: &signer,
        use_generic_resolve_function: bool,
        execution_hash: vector<u8>,
    ) acquires ApprovedExecutionHashes, GovernanceResponsbility {
        // Once expiration time has passed, the proposal should be considered resolve now as there are more yes votes
        // than no.
        timestamp::update_global_time_for_test(100001000000);
        let proposal_state = multisig_voting::get_proposal_state<GovernanceProposal>(signer::address_of(supra_framework), 0);
        assert!(proposal_state == PROPOSAL_STATE_SUCCEEDED, proposal_state);

        // Add approved script hash.
        add_supra_approved_script_hash(0);
        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@supra_framework).hashes;
        assert!(*simple_map::borrow(&approved_hashes, &0) == execution_hash, 0);

        // Resolve the proposal.
        let account = supra_resolve_proposal_for_test(0, @supra_framework, use_generic_resolve_function, true);
        assert!(signer::address_of(&account) == @supra_framework, 1);
        assert!(multisig_voting::is_resolved<GovernanceProposal>(@supra_framework, 0), 2);
        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@supra_framework).hashes;
        assert!(!simple_map::contains_key(&approved_hashes, &0), 3);
    }

    #[test(supra_framework = @supra_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_voting(
        supra_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires ApprovedExecutionHashes, SupraGovernanceConfig, GovernanceResponsbility, SupraGovernanceEvents {
        test_voting_generic(supra_framework, proposer, yes_voter, no_voter, false, false);
    }

    #[test(supra_framework = @supra_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_voting_multi_step(
        supra_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires ApprovedExecutionHashes, SupraGovernanceConfig, GovernanceResponsbility, SupraGovernanceEvents {
        test_voting_generic(supra_framework, proposer, yes_voter, no_voter, true, true);
    }

    #[test(supra_framework = @supra_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    #[expected_failure(abort_code = 0x5000a, location = supra_framework::multisig_voting)]
    public entry fun test_voting_multi_step_cannot_use_single_step_resolve(
        supra_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires ApprovedExecutionHashes, SupraGovernanceConfig, GovernanceResponsbility, SupraGovernanceEvents {
        test_voting_generic(supra_framework, proposer, yes_voter, no_voter, true, false);
    }

    #[test(supra_framework = @supra_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_voting_single_step_can_use_generic_resolve_function(
        supra_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires ApprovedExecutionHashes, SupraGovernanceConfig, GovernanceResponsbility, SupraGovernanceEvents {
        test_voting_generic(supra_framework, proposer, yes_voter, no_voter, false, true);
    }

    #[test_only]
    public entry fun test_can_remove_approved_hash_if_executed_directly_via_voting_generic(
        supra_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
        multi_step: bool,
    ) acquires ApprovedExecutionHashes, GovernanceResponsbility, SupraGovernanceEvents, SupraGovernanceConfig {
        let voters = vector[signer::address_of(proposer), signer::address_of(yes_voter), signer::address_of(no_voter)];
        supra_setup_voting(supra_framework, voters);

        supra_create_proposal_for_test(proposer, multi_step);
        supra_vote(proposer, 0, true);
        supra_vote(yes_voter, 0, true);
        supra_vote(no_voter, 0, false);

        // Add approved script hash.
        timestamp::update_global_time_for_test(100001000000);
        add_supra_approved_script_hash(0);

        // Resolve the proposal.
        if (multi_step) {
            let execution_hash = vector::empty<u8>();
            let next_execution_hash = vector::empty<u8>();
            vector::push_back(&mut execution_hash, 1);
            multisig_voting::resolve_proposal_v2<GovernanceProposal>(@supra_framework, 0, next_execution_hash);
            assert!(multisig_voting::is_resolved<GovernanceProposal>(@supra_framework, 0), 0);
            if (vector::length(&next_execution_hash) == 0) {
                remove_supra_approved_hash(0);
            } else {
                add_supra_approved_script_hash(0)
            };
        } else {
            multisig_voting::resolve<GovernanceProposal>(@supra_framework, 0);
            assert!(multisig_voting::is_resolved<GovernanceProposal>(@supra_framework, 0), 0);
            remove_supra_approved_hash(0);
        };
        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@supra_framework).hashes;
        assert!(!simple_map::contains_key(&approved_hashes, &0), 1);
    }

    #[test(supra_framework = @supra_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_can_remove_approved_hash_if_executed_directly_via_voting(
        supra_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires ApprovedExecutionHashes, GovernanceResponsbility, SupraGovernanceEvents, SupraGovernanceConfig {
        test_can_remove_approved_hash_if_executed_directly_via_voting_generic(
            supra_framework,
            proposer,
            yes_voter,
            no_voter,
            false
        );
    }

    #[test(supra_framework = @supra_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_can_remove_approved_hash_if_executed_directly_via_voting_multi_step(
        supra_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires ApprovedExecutionHashes, GovernanceResponsbility, SupraGovernanceEvents, SupraGovernanceConfig {
        test_can_remove_approved_hash_if_executed_directly_via_voting_generic(
            supra_framework,
            proposer,
            yes_voter,
            no_voter,
            true
        );
    }

    #[test(supra_framework = @supra_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    #[expected_failure(abort_code = 0x8000d, location = supra_framework::multisig_voting)]
    public entry fun test_cannot_double_vote(
        supra_framework: &signer,
        proposer: &signer,
        voter_1: &signer,
        voter_2: &signer,
    ) acquires ApprovedExecutionHashes, GovernanceResponsbility, SupraGovernanceConfig, SupraGovernanceEvents {
        let voters = vector[signer::address_of(proposer), signer::address_of(voter_1), signer::address_of(voter_2)];
        supra_setup_voting(supra_framework, voters);

        supra_create_proposal(
            proposer,
            b"random-test",
            b"",
            b"",
        );

        // Double voting should throw an error.
        supra_vote(voter_1, 0, true);
        supra_vote(voter_1, 0, true);
    }

    #[test_only]
    public fun supra_setup_voting(
        supra_framework: &signer,
        voters: vector<address>,
    ) acquires GovernanceResponsbility {
        use supra_framework::account;

        timestamp::set_time_has_started_for_testing(supra_framework);
        account::create_account_for_test(signer::address_of(supra_framework));

        // Initialize the governance.
        initialize(supra_framework, 1000, 2, voters);
        store_signer_cap(
            supra_framework,
            @supra_framework,
            account::create_test_signer_cap(@supra_framework),
        );
    }

    #[test(supra_framework = @supra_framework)]
    public entry fun test_update_governance_config(
        supra_framework: signer,
    ) acquires SupraGovernanceEvents, SupraGovernanceConfig {
        account::create_account_for_test(signer::address_of(&supra_framework));
        let voters = vector[@0xa1, @0xa2, @0xa3];
        initialize(&supra_framework, 1000, 2, voters);
        let updated_voters = vector[@0xa1, @0xa2, @0xa3, @0xa4, @0xa5];
        update_supra_governance_config(&supra_framework, 1500, 3, updated_voters);

        let supra_config = borrow_global<SupraGovernanceConfig>(@supra_framework);
        assert!(supra_config.min_voting_threshold == 3, 0);
        assert!(supra_config.voters == updated_voters, 1);
        assert!(supra_config.voting_duration_secs == 1500, 3);
    }

    #[test(account = @0x123)]
    #[expected_failure(abort_code = 0x50003, location = supra_framework::system_addresses)]
    public entry fun test_update_governance_config_unauthorized_should_fail(account: signer)
    acquires SupraGovernanceConfig, SupraGovernanceEvents {
        account::create_account_for_test(signer::address_of(&account));

        let voters = vector[@0xa1, @0xa2, @0xa3];
        initialize(&account, 1000, 2, voters);
        update_supra_governance_config(&account, 1500, 2, voters);
    }

    #[test(supra_framework = @supra_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_replace_execution_hash(
        supra_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires GovernanceResponsbility, ApprovedExecutionHashes, SupraGovernanceConfig, SupraGovernanceEvents {
        let voters = vector[signer::address_of(proposer), signer::address_of(yes_voter), signer::address_of(no_voter)];
        supra_setup_voting(supra_framework, voters);

        supra_create_proposal_for_test(proposer, true);
        supra_vote(proposer, 0, true);
        supra_vote(yes_voter, 0, true);
        supra_vote(no_voter, 0, false);

        // Add approved script hash.
        timestamp::update_global_time_for_test(100001000000);
        add_supra_approved_script_hash(0);

        // Resolve the proposal.
        let execution_hash = vector::empty<u8>();
        let next_execution_hash = vector::empty<u8>();
        vector::push_back(&mut execution_hash, 1);
        vector::push_back(&mut next_execution_hash, 10);

        multisig_voting::resolve_proposal_v2<GovernanceProposal>(@supra_framework, 0, next_execution_hash);

        if (vector::length(&next_execution_hash) == 0) {
            remove_supra_approved_hash(0);
        } else {
            add_supra_approved_script_hash(0)
        };

        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@supra_framework).hashes;
        assert!(*simple_map::borrow(&approved_hashes, &0) == vector[10u8, ], 1);
    }

    #[verify_only]
    public fun initialize_for_verification(
        supra_framework: &signer,
        voting_duration_secs: u64,
        supra_min_voting_threshold: u64,
        voters: vector<address>,
    ) {
        initialize(supra_framework, voting_duration_secs, supra_min_voting_threshold, voters);
    }
}
