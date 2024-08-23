///
/// This is the general Multisig Voting module that can be used as part of a DAO Governance. Multisig Voting is designed to be used by
/// calculation and including proper capabilities when creating the proposal so resolution can go through.
/// On-chain governance of the Supra network also uses Multisig Voting.
///
/// The Multisig voting flow:
/// 1. The Multisig Voting module can be deployed at a known address (e.g. 0x1 for Aptos on-chain governance)
/// 2. The governance module, e.g. SupraGovernance, can be deployed later and define a GovernanceProposal resource type
/// that can also contain other information such as Capability resource for authorization.
/// 3. The governance module's owner can then register the ProposalType with Multisig Voting. This also hosts the proposal list
/// (forum) on the calling account.
/// 4. A proposer, through the governance module, can call multisig_voting::create_proposal to create a proposal. create_proposal
/// cannot be called directly not through the governance module. A script hash of the resolution script that can later
/// be called to execute the proposal is required.
/// 5. A voter, through the governance module, can call multisig_voting::vote on a proposal. vote requires passing a &ProposalType
/// and thus only the governance module that registers ProposalType can call vote.
/// 6. Once the proposal's expiration time has passed and more than the defined threshold has voted yes on the proposal,
/// anyone can call resolve which returns the content of the proposal (of type ProposalType) that can be used to execute.
/// 7. Only the resolution script with the same script hash specified in the proposal can call multisig_voting::resolve as part of
/// the resolution process.
///
module supra_framework::multisig_voting {
    use std::bcs::to_bytes;
    use std::error;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{String, utf8};
    use std::vector;

    use aptos_std::from_bcs::to_u64;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::table::{Self, Table};
    use aptos_std::type_info::{Self, TypeInfo};

    use supra_framework::account;
    use supra_framework::event::{Self, EventHandle};
    use supra_framework::timestamp;
    use supra_framework::transaction_context;
    use aptos_std::from_bcs;

    /// Current script's execution hash does not match the specified proposal's
    const EPROPOSAL_EXECUTION_HASH_NOT_MATCHING: u64 = 1;
    /// Proposal cannot be resolved. Either voting duration has not passed, not enough votes, or fewer yes than no votes
    const EPROPOSAL_CANNOT_BE_RESOLVED: u64 = 2;
    /// Proposal cannot be resolved more than once
    const EPROPOSAL_ALREADY_RESOLVED: u64 = 3;
    /// Proposal cannot contain an empty execution script hash
    const EPROPOSAL_EMPTY_EXECUTION_HASH: u64 = 4;
    /// Proposal's voting period has already ended.
    const EPROPOSAL_VOTING_ALREADY_ENDED: u64 = 5;
    /// Voting forum has already been registered.
    const EVOTING_FORUM_ALREADY_REGISTERED: u64 = 6;
    /// Resolution of a proposal cannot happen atomically in the same transaction as the last vote.
    const ERESOLUTION_CANNOT_BE_ATOMIC: u64 = 8;
    /// Cannot vote if the specified multi-step proposal is in execution.
    const EMULTI_STEP_PROPOSAL_IN_EXECUTION: u64 = 9;
    /// If a proposal is multi-step, we need to use `resolve_proposal_v2()` to resolve it.
    /// If we use `resolve()` to resolve a multi-step proposal, it will fail with EMULTI_STEP_PROPOSAL_CANNOT_USE_SINGLE_STEP_RESOLVE_FUNCTION.
    const EMULTI_STEP_PROPOSAL_CANNOT_USE_SINGLE_STEP_RESOLVE_FUNCTION: u64 = 10;
    /// If we call `resolve_proposal_v2()` to resolve a single-step proposal, the `next_execution_hash` parameter should be an empty vector.
    const ESINGLE_STEP_PROPOSAL_CANNOT_HAVE_NEXT_EXECUTION_HASH: u64 = 11;
    /// Cannot call `is_multi_step_proposal_in_execution()` on single-step proposals.
    const EPROPOSAL_IS_SINGLE_STEP: u64 = 12;
    /// Cannot vote duplicate
    const EVOTE_DUPLICATE_VOTE: u64 = 13;
    /// Vote is overflow
    const EVOTE_OVERFLOW: u64 = 14;
    /// Threshold should not exceeds voters
    const ETHRESHOLD_EXCEEDS_VOTERS: u64 = 15;
    /// Not a multisig owner authorized to vote.
    const ENOT_MULTISIG_OWNER: u64 = 16;
    /// Threshold value must be greater than 1
    const ETHRESHOLD_MUST_BE_GREATER_THAN_ONE: u64 = 17;

    /// ProposalStateEnum representing proposal state.
    const PROPOSAL_STATE_PENDING: u64 = 0;
    const PROPOSAL_STATE_SUCCEEDED: u64 = 1;
    /// Proposal has failed because either the min vote threshold is not met or majority voted no.
    const PROPOSAL_STATE_FAILED: u64 = 3;

    /// Key used to track the resolvable time in the proposal's metadata.
    const RESOLVABLE_TIME_METADATA_KEY: vector<u8> = b"RESOLVABLE_TIME_METADATA_KEY";
    /// Key used to track if the proposal is multi-step
    const IS_MULTI_STEP_PROPOSAL_KEY: vector<u8> = b"IS_MULTI_STEP_PROPOSAL_KEY";
    /// Key used to track if the multi-step proposal is in execution / resolving in progress.
    const IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY: vector<u8> = b"IS_MULTI_STEP_PROPOSAL_IN_EXECUTION";

    /// Extra metadata (e.g. description, code url) can be part of the ProposalType struct.
    struct Proposal<ProposalType: store> has store {
        /// Required. The address of the proposer.
        proposer: address,

        /// Required. Should contain enough information to execute later, for example the required capability.
        /// This is stored as an option so we can return it to governance when the proposal is resolved.
        execution_content: Option<ProposalType>,

        /// Optional. Value is serialized value of an attribute.
        /// Currently, we have three attributes that are used by the voting flow.
        /// 1. RESOLVABLE_TIME_METADATA_KEY: this is used to record the resolvable time to ensure that resolution has to be done non-atomically.
        /// 2. IS_MULTI_STEP_PROPOSAL_KEY: this is used to track if a proposal is single-step or multi-step.
        /// 3. IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY: this attribute only applies to multi-step proposals. A single-step proposal will not have
        /// this field in its metadata map. The value is used to indicate if a multi-step proposal is in execution. If yes, we will disable further
        /// voting for this multi-step proposal.
        metadata: SimpleMap<String, vector<u8>>,

        /// Timestamp when the proposal was created.
        creation_time_secs: u64,

        /// Required. The hash for the execution script module. Only the same exact script module can resolve this
        /// proposal.
        execution_hash: vector<u8>,

        /// A proposal is only resolved if expiration has passed and the number of votes is above threshold.
        min_vote_threshold: u64,
        expiration_secs: u64,

        /// Number of votes for each outcome.
        yes_votes: u64,
        no_votes: u64,

        /// list of voters
        voters: vector<address>,

        /// list of voters who completed their vote
        voted_records: table::Table<address, bool>,

        /// Whether the proposal has been resolved.
        is_resolved: bool,
        /// Resolution timestamp if the proposal has been resolved. 0 otherwise.
        resolution_time_secs: u64,
    }

    struct VotingForum<ProposalType: store> has key {
        /// Use Table for execution optimization instead of Vector for gas cost since Vector is read entirely into memory
        /// during execution while only relevant Table entries are.
        proposals: Table<u64, Proposal<ProposalType>>,
        events: VotingEvents,
        /// Unique identifier for a proposal. This allows for 2 * 10**19 proposals.
        next_proposal_id: u64,
    }

    struct VotingEvents has store {
        create_proposal_events: EventHandle<CreateProposalEvent>,
        register_forum_events: EventHandle<RegisterForumEvent>,
        resolve_proposal_events: EventHandle<ResolveProposal>,
        vote_events: EventHandle<VoteEvent>,
    }

    #[event]
    struct CreateProposal has drop, store {
        proposal_id: u64,
        execution_hash: vector<u8>,
        expiration_secs: u64,
        metadata: SimpleMap<String, vector<u8>>,
        min_vote_threshold: u64,
    }

    #[event]
    struct RegisterForum has drop, store {
        hosting_account: address,
        proposal_type_info: TypeInfo,
    }

    #[event]
    struct Vote has drop, store {
        voter: address,
        proposal_id: u64,
        is_vote_yes: bool,
    }

    #[event]
    struct ResolveProposal has drop, store {
        proposal_id: u64,
        yes_votes: u64,
        no_votes: u64,
        resolved_early: bool
    }

    struct CreateProposalEvent has drop, store {
        proposal_id: u64,
        execution_hash: vector<u8>,
        expiration_secs: u64,
        metadata: SimpleMap<String, vector<u8>>,
        min_vote_threshold: u64,
    }

    struct RegisterForumEvent has drop, store {
        hosting_account: address,
        proposal_type_info: TypeInfo,
    }

    struct VoteEvent has drop, store {
        voter: address,
        proposal_id: u64,
        is_vote_yes: bool,
    }

    public fun register<ProposalType: store>(account: &signer) {
        let addr = signer::address_of(account);
        assert!(!exists<VotingForum<ProposalType>>(addr), error::already_exists(EVOTING_FORUM_ALREADY_REGISTERED));

        let voting_forum = VotingForum<ProposalType> {
            next_proposal_id: 0,
            proposals: table::new<u64, Proposal<ProposalType>>(),
            events: VotingEvents {
                create_proposal_events: account::new_event_handle<CreateProposalEvent>(account),
                register_forum_events: account::new_event_handle<RegisterForumEvent>(account),
                resolve_proposal_events: account::new_event_handle<ResolveProposal>(account),
                vote_events: account::new_event_handle<VoteEvent>(account),
            }
        };

        if (std::features::module_event_migration_enabled()) {
            event::emit(
                RegisterForum {
                    hosting_account: addr,
                    proposal_type_info: type_info::type_of<ProposalType>(),
                },
            );
        };
        event::emit_event<RegisterForumEvent>(
            &mut voting_forum.events.register_forum_events,
            RegisterForumEvent {
                hosting_account: addr,
                proposal_type_info: type_info::type_of<ProposalType>(),
            },
        );

        move_to(account, voting_forum);
    }

    /// Create a single-step proposal with the given parameters
    ///
    /// @param voting_forum_address The forum's address where the proposal will be stored.
    /// @param execution_content The execution content that will be given back at resolution time. This can contain
    /// data such as a capability resource used to scope the execution.
    /// @param execution_hash The hash for the execution script module. Only the same exact script module can resolve
    /// this proposal.
    /// @param min_vote_threshold The minimum number of votes needed to consider this proposal successful.
    /// @param expiration_secs The time in seconds at which the proposal expires and can potentially be resolved.
    /// @param metadata A simple_map that stores information about this proposal.
    /// @return The proposal id.
    public fun create_proposal<ProposalType: store>(
        proposer: address,
        voting_forum_address: address,
        execution_content: ProposalType,
        execution_hash: vector<u8>,
        min_vote_threshold: u64,
        voters: vector<address>,
        expiration_secs: u64,
        metadata: SimpleMap<String, vector<u8>>,
    ): u64 acquires VotingForum {
        create_proposal_v2(
            proposer,
            voting_forum_address,
            execution_content,
            execution_hash,
            min_vote_threshold,
            voters,
            expiration_secs,
            metadata,
            false
        )
    }

    /// Create a single-step or a multi-step proposal with the given parameters
    ///
    /// @param voting_forum_address The forum's address where the proposal will be stored.
    /// @param execution_content The execution content that will be given back at resolution time. This can contain
    /// data such as a capability resource used to scope the execution.
    /// @param execution_hash The sha-256 hash for the execution script module. Only the same exact script module can
    /// resolve this proposal.
    /// @param min_vote_threshold The minimum number of votes needed to consider this proposal successful.
    /// @param voters The list of voters who are eligible to vote.".
    /// @param expiration_secs The time in seconds at which the proposal expires and can potentially be resolved.
    /// @param metadata A simple_map that stores information about this proposal.
    /// @param is_multi_step_proposal A bool value that indicates if the proposal is single-step or multi-step.
    /// @return The proposal id.
    public fun create_proposal_v2<ProposalType: store>(
        proposer: address,
        voting_forum_address: address,
        execution_content: ProposalType,
        execution_hash: vector<u8>,
        min_vote_threshold: u64,
        voters: vector<address>,
        expiration_secs: u64,
        metadata: SimpleMap<String, vector<u8>>,
        is_multi_step_proposal: bool,
    ): u64 acquires VotingForum {

        // Make sure the execution script's hash is not empty.
        assert!(vector::length(&execution_hash) > 0, error::invalid_argument(EPROPOSAL_EMPTY_EXECUTION_HASH));

        assert!(min_vote_threshold > 1, error::invalid_argument(ETHRESHOLD_MUST_BE_GREATER_THAN_ONE));

        // Make sure voters length must greater or equal  to vote threshold
        assert!(vector::length(&voters) >= min_vote_threshold, error::invalid_argument(ETHRESHOLD_EXCEEDS_VOTERS));

        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal_id = voting_forum.next_proposal_id;
        voting_forum.next_proposal_id = voting_forum.next_proposal_id + 1;

        // Add a flag to indicate if this proposal is single-step or multi-step.
        simple_map::add(&mut metadata, utf8(IS_MULTI_STEP_PROPOSAL_KEY), to_bytes(&is_multi_step_proposal));

        let is_multi_step_in_execution_key = utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY);
        if (is_multi_step_proposal) {
            // If the given proposal is a multi-step proposal, we will add a flag to indicate if this multi-step proposal is in execution.
            // This value is by default false. We turn this value to true when we start executing the multi-step proposal. This value
            // will be used to disable further voting after we started executing the multi-step proposal.
            simple_map::add(&mut metadata, is_multi_step_in_execution_key, to_bytes(&false));
            // If the proposal is a single-step proposal, we check if the metadata passed by the client has the IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY key.
            // If they have the key, we will remove it, because a single-step proposal that doesn't need this key.
        } else if (simple_map::contains_key(&mut metadata, &is_multi_step_in_execution_key)) {
            simple_map::remove(&mut metadata, &is_multi_step_in_execution_key);
        };

        table::add(&mut voting_forum.proposals, proposal_id, Proposal {
            proposer,
            creation_time_secs: timestamp::now_seconds(),
            execution_content: option::some<ProposalType>(execution_content),
            execution_hash,
            metadata,
            min_vote_threshold,
            voters,
            expiration_secs,
            yes_votes: 0,
            no_votes: 0,
            voted_records: table::new(),
            is_resolved: false,
            resolution_time_secs: 0,
        });

        if (std::features::module_event_migration_enabled()) {
            event::emit(
                CreateProposal {
                    proposal_id,
                    execution_hash,
                    expiration_secs,
                    metadata,
                    min_vote_threshold,
                },
            );
        };
        event::emit_event<CreateProposalEvent>(
            &mut voting_forum.events.create_proposal_events,
            CreateProposalEvent {
                proposal_id,
                execution_hash,
                expiration_secs,
                metadata,
                min_vote_threshold,
            },
        );

        proposal_id
    }

    /// Vote on the given proposal.
    ///
    /// @param _proof Required so only the governance module that defines ProposalType can initiate voting.
    /// @param voter signer of the voter.
    /// @param voting_forum_address The address of the forum where the proposals are stored.
    /// @param proposal_id The proposal id.
    /// @param should_pass Whether the votes are for yes or no.
    public fun vote<ProposalType: store>(
        voter: &signer,
        _proof: &ProposalType,
        voting_forum_address: address,
        proposal_id: u64,
        should_pass: bool,
    ) acquires VotingForum {
        let voter_address = signer::address_of(voter);
        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);

        assert!(vector::contains(&proposal.voters, &voter_address), error::permission_denied(ENOT_MULTISIG_OWNER));

        // Voting might still be possible after the proposal has enough yes votes to be resolved early. This would only
        // lead to possible proposal resolution failure if the resolve early threshold is not definitive (e.g. < 50% + 1
        // of the total voting token's supply). In this case, more voting might actually still be desirable.
        // Governance mechanisms built on this voting module can apply additional rules on when voting is closed as
        // appropriate.
        assert!(!is_voting_period_over(proposal), error::invalid_state(EPROPOSAL_VOTING_ALREADY_ENDED));
        assert!(!proposal.is_resolved, error::invalid_state(EPROPOSAL_ALREADY_RESOLVED));
        // Assert this proposal is single-step, or if the proposal is multi-step, it is not in execution yet.
        assert!(!simple_map::contains_key(&proposal.metadata, &utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY))
            || *simple_map::borrow(&proposal.metadata, &utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY)) == to_bytes(
            &false
        ),
            error::invalid_state(EMULTI_STEP_PROPOSAL_IN_EXECUTION));

        if (table::contains(&proposal.voted_records, voter_address)) {
            let voted_record = table::borrow_mut(&mut proposal.voted_records, voter_address);
            assert!(voted_record != &should_pass, error::already_exists(EVOTE_DUPLICATE_VOTE));
            *voted_record = should_pass;

            if (should_pass) {
                proposal.yes_votes = proposal.yes_votes + 1;
                // Since the entry existed in `voted_records`, the vote flip should be reflected by this subtraction
                proposal.no_votes = proposal.no_votes - 1;
            } else {
                // Since the voter already voted and flipping the vote here, this subtraction is needed.
                proposal.yes_votes = proposal.yes_votes - 1;
                proposal.no_votes = proposal.no_votes + 1;
            };
        } else {
            // vote cannot be more than `max_vote_number`
            assert!(proposal.yes_votes + proposal.no_votes < vector::length(&proposal.voters), error::invalid_state(EVOTE_OVERFLOW));

            if (should_pass) {
                proposal.yes_votes = proposal.yes_votes + 1;
            } else {
                proposal.no_votes = proposal.no_votes + 1;
            };
            table::add(&mut proposal.voted_records, voter_address, should_pass);
        };

        // Record the resolvable time to ensure that resolution has to be done non-atomically.
        let timestamp_secs_bytes = to_bytes(&timestamp::now_seconds());
        let key = utf8(RESOLVABLE_TIME_METADATA_KEY);
        simple_map::upsert(&mut proposal.metadata, key, timestamp_secs_bytes);

        if (std::features::module_event_migration_enabled()) {
            event::emit(Vote { proposal_id, is_vote_yes: should_pass, voter: voter_address });
        };
        event::emit_event<VoteEvent>(
            &mut voting_forum.events.vote_events,
            VoteEvent { proposal_id, is_vote_yes: should_pass, voter: voter_address },
        );
    }

    /// Common checks on if a proposal is resolvable, regardless if the proposal is single-step or multi-step.
    fun is_proposal_resolvable<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ) acquires VotingForum {
        let proposal_state = get_proposal_state<ProposalType>(voting_forum_address, proposal_id);
        assert!(proposal_state == PROPOSAL_STATE_SUCCEEDED, error::invalid_state(EPROPOSAL_CANNOT_BE_RESOLVED));

        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);
        assert!(!proposal.is_resolved, error::invalid_state(EPROPOSAL_ALREADY_RESOLVED));

        // We need to make sure that the resolution is happening in
        // a separate transaction from the last vote to guard against any potential flashloan attacks.
        let resolvable_time = to_u64(*simple_map::borrow(&proposal.metadata, &utf8(RESOLVABLE_TIME_METADATA_KEY)));
        assert!(timestamp::now_seconds() > resolvable_time, error::invalid_state(ERESOLUTION_CANNOT_BE_ATOMIC));

        assert!(
            transaction_context::get_script_hash() == proposal.execution_hash,
            error::invalid_argument(EPROPOSAL_EXECUTION_HASH_NOT_MATCHING),
        );
    }

    /// Resolve a single-step proposal with given id. Can only be done if there are at least as many votes as min required and
    /// there are more yes votes than no. If either of these conditions is not met, this will revert.
    ///
    /// @param voting_forum_address The address of the forum where the proposals are stored.
    /// @param proposal_id The proposal id.
    public fun resolve<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): ProposalType acquires VotingForum {
        is_proposal_resolvable<ProposalType>(voting_forum_address, proposal_id);

        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);

        // Assert that the specified proposal is not a multi-step proposal.
        let multi_step_key = utf8(IS_MULTI_STEP_PROPOSAL_KEY);
        let has_multi_step_key = simple_map::contains_key(&proposal.metadata, &multi_step_key);
        if (has_multi_step_key) {
            let is_multi_step_proposal = from_bcs::to_bool(*simple_map::borrow(&proposal.metadata, &multi_step_key));
            assert!(
                !is_multi_step_proposal,
                error::permission_denied(EMULTI_STEP_PROPOSAL_CANNOT_USE_SINGLE_STEP_RESOLVE_FUNCTION)
            );
        };

        let resolved_early = can_be_resolved_early(proposal);
        proposal.is_resolved = true;
        proposal.resolution_time_secs = timestamp::now_seconds();

        if (std::features::module_event_migration_enabled()) {
            event::emit(
                ResolveProposal {
                    proposal_id,
                    yes_votes: proposal.yes_votes,
                    no_votes: proposal.no_votes,
                    resolved_early,
                },
            );
        };
        event::emit_event<ResolveProposal>(
            &mut voting_forum.events.resolve_proposal_events,
            ResolveProposal {
                proposal_id,
                yes_votes: proposal.yes_votes,
                no_votes: proposal.no_votes,
                resolved_early,
            },
        );

        option::extract(&mut proposal.execution_content)
    }

    /// Resolve a single-step or a multi-step proposal with the given id.
    /// Can only be done if there are at least as many votes as min required and
    /// there are more yes votes than no. If either of these conditions is not met, this will revert.
    ///
    ///
    /// @param voting_forum_address The address of the forum where the proposals are stored.
    /// @param proposal_id The proposal id.
    /// @param next_execution_hash The next execution hash if the given proposal is multi-step.
    public fun resolve_proposal_v2<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
        next_execution_hash: vector<u8>,
    ) acquires VotingForum {
        is_proposal_resolvable<ProposalType>(voting_forum_address, proposal_id);

        let voting_forum = borrow_global_mut<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);

        // Update the IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY key to indicate that the multi-step proposal is in execution.
        let multi_step_in_execution_key = utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY);
        if (simple_map::contains_key(&proposal.metadata, &multi_step_in_execution_key)) {
            let is_multi_step_proposal_in_execution_value = simple_map::borrow_mut(
                &mut proposal.metadata,
                &multi_step_in_execution_key
            );
            *is_multi_step_proposal_in_execution_value = to_bytes(&true);
        };

        let multi_step_key = utf8(IS_MULTI_STEP_PROPOSAL_KEY);
        let is_multi_step = simple_map::contains_key(&proposal.metadata, &multi_step_key) && from_bcs::to_bool(
            *simple_map::borrow(&proposal.metadata, &multi_step_key)
        );
        let next_execution_hash_is_empty = vector::length(&next_execution_hash) == 0;

        // Assert that if this proposal is single-step, the `next_execution_hash` parameter is empty.
        assert!(
            is_multi_step || next_execution_hash_is_empty,
            error::invalid_argument(ESINGLE_STEP_PROPOSAL_CANNOT_HAVE_NEXT_EXECUTION_HASH)
        );

        // If the `next_execution_hash` parameter is empty, it means that either
        // - this proposal is a single-step proposal, or
        // - this proposal is multi-step and we're currently resolving the last step in the multi-step proposal.
        // We can mark that this proposal is resolved.
        if (next_execution_hash_is_empty) {
            proposal.is_resolved = true;
            proposal.resolution_time_secs = timestamp::now_seconds();

            // Set the `IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY` value to false upon successful resolution of the last step of a multi-step proposal.
            if (is_multi_step) {
                let is_multi_step_proposal_in_execution_value = simple_map::borrow_mut(
                    &mut proposal.metadata,
                    &multi_step_in_execution_key
                );
                *is_multi_step_proposal_in_execution_value = to_bytes(&false);
            };
        } else {
            // If the current step is not the last step,
            // update the proposal's execution hash on-chain to the execution hash of the next step.
            proposal.execution_hash = next_execution_hash;
        };

        // For single-step proposals, we emit one `ResolveProposal` event per proposal.
        // For multi-step proposals, we emit one `ResolveProposal` event per step in the multi-step proposal. This means
        // that we emit multiple `ResolveProposal` events for the same multi-step proposal.
        let resolved_early = can_be_resolved_early(proposal);
        if (std::features::module_event_migration_enabled()) {
            event::emit(
                ResolveProposal {
                    proposal_id,
                    yes_votes: proposal.yes_votes,
                    no_votes: proposal.no_votes,
                    resolved_early,
                },
            );
        };
        event::emit_event(
            &mut voting_forum.events.resolve_proposal_events,
            ResolveProposal {
                proposal_id,
                yes_votes: proposal.yes_votes,
                no_votes: proposal.no_votes,
                resolved_early,
            },
        );

    }

    #[view]
    /// Return the next unassigned proposal id
    public fun next_proposal_id<ProposalType: store>(voting_forum_address: address, ): u64 acquires VotingForum {
        let voting_forum = borrow_global<VotingForum<ProposalType>>(voting_forum_address);
        voting_forum.next_proposal_id
    }

    #[view]
    public fun get_proposer<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64
    ): address acquires VotingForum {
        let proposal = get_proposal<ProposalType>(voting_forum_address, proposal_id);
        proposal.proposer
    }

    #[view]
    public fun is_voting_closed<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64
    ): bool acquires VotingForum {
        let proposal = get_proposal<ProposalType>(voting_forum_address, proposal_id);
        can_be_resolved_early(proposal) || is_voting_period_over(proposal)
    }

    /// Return true if the proposal has reached early resolution threshold (if specified).
    public fun can_be_resolved_early<ProposalType: store>(proposal: &Proposal<ProposalType>): bool {
        if (proposal.yes_votes >= proposal.min_vote_threshold || proposal.no_votes >= vector::length(&proposal.voters) - proposal.min_vote_threshold + 1) {
            return true
        };
        false
    }

    #[view]
    public fun get_proposal_metadata<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): SimpleMap<String, vector<u8>> acquires VotingForum {
        let proposal = get_proposal<ProposalType>(voting_forum_address, proposal_id);
        proposal.metadata
    }

    #[view]
    public fun get_proposal_metadata_value<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
        metadata_key: String,
    ): vector<u8> acquires VotingForum {
        let proposal = get_proposal<ProposalType>(voting_forum_address, proposal_id);
        *simple_map::borrow(&proposal.metadata, &metadata_key)
    }

    #[view]
    /// Return the state of the proposal with given id.
    ///
    /// @param voting_forum_address The address of the forum where the proposals are stored.
    /// @param proposal_id The proposal id.
    /// @return Proposal state as an enum value.
    public fun get_proposal_state<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): u64 acquires VotingForum {
        if (is_voting_closed<ProposalType>(voting_forum_address, proposal_id)) {
            let proposal = get_proposal<ProposalType>(voting_forum_address, proposal_id);
            if (proposal.yes_votes >= proposal.min_vote_threshold) {
                PROPOSAL_STATE_SUCCEEDED
            } else {
                PROPOSAL_STATE_FAILED
            }
        } else {
            PROPOSAL_STATE_PENDING
        }
    }

    #[view]
    /// Return the proposal's creation time.
    public fun get_proposal_creation_secs<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): u64 acquires VotingForum {
        let proposal = get_proposal<ProposalType>(voting_forum_address, proposal_id);
        proposal.creation_time_secs
    }

    #[view]
    /// Return the proposal's expiration time.
    public fun get_proposal_expiration_secs<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): u64 acquires VotingForum {
        let proposal = get_proposal<ProposalType>(voting_forum_address, proposal_id);
        proposal.expiration_secs
    }

    #[view]
    /// Return the proposal's execution hash.
    public fun get_execution_hash<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): vector<u8> acquires VotingForum {
        let proposal = get_proposal<ProposalType>(voting_forum_address, proposal_id);
        proposal.execution_hash
    }

    #[view]
    /// Return the proposal's minimum vote threshold
    public fun get_min_vote_threshold<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): u64 acquires VotingForum {
        let proposal = get_proposal<ProposalType>(voting_forum_address, proposal_id);
        proposal.min_vote_threshold
    }

    #[view]
    /// Return the proposal's current vote count (yes_votes, no_votes)
    public fun get_votes<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): (u64, u64) acquires VotingForum {
        let proposal = get_proposal<ProposalType>(voting_forum_address, proposal_id);
        (proposal.yes_votes, proposal.no_votes)
    }

    #[view]
    /// Return true if the governance proposal has already been resolved.
    public fun is_resolved<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): bool acquires VotingForum {
        let proposal = get_proposal<ProposalType>(voting_forum_address, proposal_id);
        proposal.is_resolved
    }

    #[view]
    public fun get_resolution_time_secs<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): u64 acquires VotingForum {
        let proposal = get_proposal<ProposalType>(voting_forum_address, proposal_id);
        proposal.resolution_time_secs
    }

    #[view]
    /// Return true if the multi-step governance proposal is in execution.
    public fun is_multi_step_proposal_in_execution<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): bool acquires VotingForum {
        let voting_forum = borrow_global<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::borrow(&voting_forum.proposals, proposal_id);
        let is_multi_step_in_execution_key = utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY);
        assert!(
            simple_map::contains_key(&proposal.metadata, &is_multi_step_in_execution_key),
            error::invalid_argument(EPROPOSAL_IS_SINGLE_STEP)
        );
        from_bcs::to_bool(*simple_map::borrow(&proposal.metadata, &is_multi_step_in_execution_key))
    }

    /// Return true if the voting period of the given proposal has already ended.
    fun is_voting_period_over<ProposalType: store>(proposal: &Proposal<ProposalType>): bool {
        timestamp::now_seconds() > proposal.expiration_secs
    }

    inline fun get_proposal<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): &Proposal<ProposalType> acquires VotingForum {
        let voting_forum = borrow_global<VotingForum<ProposalType>>(voting_forum_address);
        table::borrow(&voting_forum.proposals, proposal_id)
    }

    #[test_only]
    struct TestProposal has store {}

    #[test_only]
    const VOTING_DURATION_SECS: u64 = 100000;

    #[test_only]
    public fun create_test_proposal_generic(
        governance: &signer,
        use_generic_create_proposal_function: bool,
        voters: vector<address>,
    ): u64 acquires VotingForum {
        // Register voting forum and create a proposal.
        register<TestProposal>(governance);
        let governance_address = signer::address_of(governance);
        let proposal = TestProposal {};

        // This works because our Move unit test extensions mock out the execution hash to be [1].
        let execution_hash = vector::empty<u8>();
        vector::push_back(&mut execution_hash, 1);
        let metadata = simple_map::create<String, vector<u8>>();

        if (use_generic_create_proposal_function) {
            create_proposal_v2<TestProposal>(
                governance_address,
                governance_address,
                proposal,
                execution_hash,
                2,
                voters,
                timestamp::now_seconds() + VOTING_DURATION_SECS,
                metadata,
                use_generic_create_proposal_function
            )
        } else {
            create_proposal<TestProposal>(
                governance_address,
                governance_address,
                proposal,
                execution_hash,
                2,
                voters,
                timestamp::now_seconds() + VOTING_DURATION_SECS,
                metadata,
            )
        }
    }

    #[test_only]
    public fun resolve_proposal_for_test<ProposalType>(
        voting_forum_address: address,
        proposal_id: u64,
        is_multi_step: bool,
        finish_multi_step_execution: bool
    ) acquires VotingForum {
        if (is_multi_step) {
            let execution_hash = vector::empty<u8>();
            vector::push_back(&mut execution_hash, 1);
            resolve_proposal_v2<TestProposal>(voting_forum_address, proposal_id, execution_hash);

            if (finish_multi_step_execution) {
                resolve_proposal_v2<TestProposal>(voting_forum_address, proposal_id, vector::empty<u8>());
            };
        } else {
            let proposal = resolve<TestProposal>(voting_forum_address, proposal_id);
            let TestProposal {} = proposal;
        };
    }

    #[test_only]
    public fun create_test_proposal(
        governance: &signer,
        voters: vector<address>,
    ): u64 acquires VotingForum {
        create_test_proposal_generic(governance, false, voters)
    }

    #[test_only]
    public fun create_proposal_with_empty_execution_hash_should_fail_generic(
        governance: &signer,
        is_multi_step: bool
    ) acquires VotingForum {
        account::create_account_for_test(@supra_framework);
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        register<TestProposal>(governance);
        let proposal = TestProposal {};
        let voters = vector[@0xa1, @0xa2, @0xa3];

        // This should fail because execution hash is empty.
        if (is_multi_step) {
            create_proposal_v2<TestProposal>(
                governance_address,
                governance_address,
                proposal,
                b"",
                2,
                voters,
                100000,
                simple_map::create<String, vector<u8>>(),
                is_multi_step
            );
        } else {
            create_proposal<TestProposal>(
                governance_address,
                governance_address,
                proposal,
                b"",
                2,
                voters,
                100000,
                simple_map::create<String, vector<u8>>(),
            );
        };
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    public fun test_proposal_view_function(supra_framework: &signer, governance: &signer) acquires VotingForum {
        account::create_account_for_test(@supra_framework);
        timestamp::set_time_has_started_for_testing(supra_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let voters = vector[@0xa1, @0xa2, @0xa3];
        let proposal_id = create_test_proposal_generic(governance, true, voters);

        assert!(next_proposal_id<TestProposal>(governance_address) == 1, 1);
        assert!(get_proposer<TestProposal>(governance_address, proposal_id) == governance_address, 2);
        assert!(!is_voting_closed<TestProposal>(governance_address, proposal_id), 3);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_PENDING, 4);
        assert!(get_proposal_creation_secs<TestProposal>(governance_address, proposal_id) == timestamp::now_seconds(), 5);
        assert!(get_proposal_expiration_secs<TestProposal>(governance_address, proposal_id) == timestamp::now_seconds() + VOTING_DURATION_SECS, 6);
        assert!(get_execution_hash<TestProposal>(governance_address, proposal_id) == vector[1], 7);
        assert!(get_min_vote_threshold<TestProposal>(governance_address, proposal_id) == 2, 8);
        let (yes_vote, no_vote) = get_votes<TestProposal>(governance_address, proposal_id);
        assert!(yes_vote == 0 && no_vote == 0, 9);
        assert!(!is_resolved<TestProposal>(governance_address, proposal_id), 10);
        assert!(!is_multi_step_proposal_in_execution<TestProposal>(governance_address, proposal_id), 11);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x50010, location = Self)]
    public fun test_vote_from_different_voter_fail(supra_framework: &signer, governance: &signer) acquires VotingForum {
        account::create_account_for_test(@supra_framework);
        timestamp::set_time_has_started_for_testing(supra_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let voters = vector[@0xa1, @0xa2, @0xa3];
        let proposal_id = create_test_proposal_generic(governance, true, voters);

        // Vote from differen account which is multisig owner list.
        let proof = TestProposal {};
        vote<TestProposal>(&account::create_signer_for_test(@0xa11), &proof, governance_address, proposal_id, true);
        let TestProposal {} = proof;
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x8000D, location = Self)]
    public fun test_vote_duplicate_fail(supra_framework: &signer, governance: &signer) acquires VotingForum {
        account::create_account_for_test(@supra_framework);
        timestamp::set_time_has_started_for_testing(supra_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let voters = vector[@0xa1, @0xa2, @0xa3];
        let proposal_id = create_test_proposal_generic(governance, true, voters);

        // Vote from differen account which is multisig owner list.
        let proof = TestProposal {};
        vote<TestProposal>(&account::create_signer_for_test(@0xa1), &proof, governance_address, proposal_id, true);
        vote<TestProposal>(&account::create_signer_for_test(@0xa1), &proof, governance_address, proposal_id, true);
        let TestProposal {} = proof;
    }

    #[test(governance = @0x123)]
    #[expected_failure(abort_code = 0x10004, location = Self)]
    public fun create_proposal_with_empty_execution_hash_should_fail(governance: &signer) acquires VotingForum {
        create_proposal_with_empty_execution_hash_should_fail_generic(governance, false);
    }

    #[test(governance = @0x123)]
    #[expected_failure(abort_code = 0x10004, location = Self)]
    public fun create_proposal_with_empty_execution_hash_should_fail_multi_step(
        governance: &signer
    ) acquires VotingForum {
        create_proposal_with_empty_execution_hash_should_fail_generic(governance, true);
    }

    #[test_only]
    public entry fun test_voting_passed_generic(
        supra_framework: &signer,
        governance: &signer,
        use_create_multi_step: bool,
        use_resolve_multi_step: bool
    ) acquires VotingForum {
        account::create_account_for_test(@supra_framework);
        timestamp::set_time_has_started_for_testing(supra_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let voters = vector[@0xa1, @0xa2, @0xa3];
        let proposal_id = create_test_proposal_generic(governance, use_create_multi_step, voters);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_PENDING, 0);

        // Vote.
        let proof = TestProposal {};
        vote<TestProposal>( &account::create_signer_for_test(@0xa1), &proof, governance_address, proposal_id, true);
        vote<TestProposal>(&account::create_signer_for_test(@0xa2), &proof, governance_address, proposal_id, true);
        let TestProposal {} = proof;

        // Resolve.
        timestamp::fast_forward_seconds(VOTING_DURATION_SECS + 1);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_SUCCEEDED, 1);

        // This if statement is specifically for the test `test_voting_passed_single_step_can_use_generic_function()`.
        // It's testing when we have a single-step proposal that was created by the single-step `create_proposal()`,
        // we should be able to successfully resolve it using the generic `resolve_proposal_v2` function.
        if (!use_create_multi_step && use_resolve_multi_step) {
            resolve_proposal_v2<TestProposal>(governance_address, proposal_id, vector::empty<u8>());
        } else {
            resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, use_resolve_multi_step, true);
        };
        let voting_forum = borrow_global<VotingForum<TestProposal>>(governance_address);
        assert!(table::borrow(&voting_forum.proposals, proposal_id).is_resolved, 2);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    public entry fun test_voting_passed(supra_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_passed_generic(supra_framework, governance, false, false);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    public entry fun test_voting_passed_multi_step(supra_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_passed_generic(supra_framework, governance, true, true);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x5000a, location = Self)]
    public entry fun test_voting_passed_multi_step_cannot_use_single_step_resolve_function(
        supra_framework: &signer,
        governance: &signer
    ) acquires VotingForum {
        test_voting_passed_generic(supra_framework, governance, true, false);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    public entry fun test_voting_passed_single_step_can_use_generic_function(
        supra_framework: &signer,
        governance: &signer
    ) acquires VotingForum {
        test_voting_passed_generic(supra_framework, governance, false, true);
    }

    #[test_only]
    public entry fun test_cannot_resolve_twice_generic(
        supra_framework: &signer,
        governance: &signer,
        is_multi_step: bool
    ) acquires VotingForum {
        account::create_account_for_test(@supra_framework);
        timestamp::set_time_has_started_for_testing(supra_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let voters = vector[@0xa1, @0xa2, @0xa3];
        let proposal_id = create_test_proposal_generic(governance, is_multi_step, voters);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_PENDING, 0);

        // Vote.
        let proof = TestProposal {};
        vote<TestProposal>(&account::create_signer_for_test(@0xa1), &proof, governance_address, proposal_id, true);
        vote<TestProposal>(&account::create_signer_for_test(@0xa2), &proof, governance_address, proposal_id, true);
        let TestProposal {} = proof;

        // Resolve.
        timestamp::fast_forward_seconds(VOTING_DURATION_SECS + 1);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_SUCCEEDED, 1);
        resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, is_multi_step, true);
        resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, is_multi_step, true);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30003, location = Self)]
    public entry fun test_cannot_resolve_twice(supra_framework: &signer, governance: &signer) acquires VotingForum {
        test_cannot_resolve_twice_generic(supra_framework, governance, false);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30003, location = Self)]
    public entry fun test_cannot_resolve_twice_multi_step(
        supra_framework: &signer,
        governance: &signer
    ) acquires VotingForum {
        test_cannot_resolve_twice_generic(supra_framework, governance, true);
    }

    #[test_only]
    public entry fun test_voting_passed_early_generic(
        supra_framework: &signer,
        governance: &signer,
        is_multi_step: bool
    ) acquires VotingForum {
        account::create_account_for_test(@supra_framework);
        timestamp::set_time_has_started_for_testing(supra_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let voters = vector[@0xa1, @0xa2, @0xa3];
        let proposal_id = create_test_proposal_generic(governance, is_multi_step, voters);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_PENDING, 0);

        // Assert that IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY has value `false` in proposal.metadata.
        if (is_multi_step) {
            assert!(!is_multi_step_proposal_in_execution<TestProposal>(governance_address, 0), 1);
        };

        // Vote.
        let proof = TestProposal {};
        vote<TestProposal>(&account::create_signer_for_test(@0xa1), &proof, governance_address, proposal_id, true);
        vote<TestProposal>(&account::create_signer_for_test(@0xa2), &proof, governance_address, proposal_id, true);
        vote<TestProposal>(&account::create_signer_for_test(@0xa3), &proof, governance_address, proposal_id, false);
        let TestProposal {} = proof;

        // Resolve early. Need to increase timestamp as resolution cannot happen in the same tx.
        timestamp::fast_forward_seconds(1);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_SUCCEEDED, 2);

        if (is_multi_step) {
            // Assert that IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY still has value `false` in proposal.metadata before execution.
            assert!(!is_multi_step_proposal_in_execution<TestProposal>(governance_address, 0), 3);
            resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, is_multi_step, false);

            // Assert that the multi-step proposal is in execution but not resolved yet.
            assert!(is_multi_step_proposal_in_execution<TestProposal>(governance_address, 0), 4);
            let voting_forum = borrow_global_mut<VotingForum<TestProposal>>(governance_address);
            let proposal = table::borrow_mut(&mut voting_forum.proposals, proposal_id);
            assert!(!proposal.is_resolved, 5);
        };

        resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, is_multi_step, true);
        let voting_forum = borrow_global_mut<VotingForum<TestProposal>>(governance_address);
        assert!(table::borrow(&voting_forum.proposals, proposal_id).is_resolved, 6);

        // Assert that the IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY value is set back to `false` upon successful resolution of this multi-step proposal.
        if (is_multi_step) {
            assert!(!is_multi_step_proposal_in_execution<TestProposal>(governance_address, 0), 7);
        };
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    public entry fun test_voting_passed_early(supra_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_passed_early_generic(supra_framework, governance, false);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    public entry fun test_voting_passed_early_multi_step(
        supra_framework: &signer,
        governance: &signer
    ) acquires VotingForum {
        test_voting_passed_early_generic(supra_framework, governance, true);
    }

    #[test_only]
    public entry fun test_voting_passed_early_in_same_tx_should_fail_generic(
        supra_framework: &signer,
        governance: &signer,
        is_multi_step: bool
    ) acquires VotingForum {
        account::create_account_for_test(@supra_framework);
        timestamp::set_time_has_started_for_testing(supra_framework);
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let voters = vector[@0xa1, @0xa2, @0xa3];
        let proposal_id = create_test_proposal_generic(governance, is_multi_step, voters);
        let proof = TestProposal {};
        vote<TestProposal>(&account::create_signer_for_test(@0xa1), &proof, governance_address, proposal_id, true);
        vote<TestProposal>(&account::create_signer_for_test(@0xa2), &proof, governance_address, proposal_id, true);
        let TestProposal {} = proof;

        // Resolving early should fail since timestamp hasn't changed since the last vote.
        resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, is_multi_step, true);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30008, location = Self)]
    public entry fun test_voting_passed_early_in_same_tx_should_fail(
        supra_framework: &signer,
        governance: &signer
    ) acquires VotingForum {
        test_voting_passed_early_in_same_tx_should_fail_generic(supra_framework, governance, false);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30008, location = Self)]
    public entry fun test_voting_passed_early_in_same_tx_should_fail_multi_step(
        supra_framework: &signer,
        governance: &signer
    ) acquires VotingForum {
        test_voting_passed_early_in_same_tx_should_fail_generic(supra_framework, governance, true);
    } // Sure,

    #[test_only]
    public entry fun test_voting_failed_generic(
        supra_framework: &signer,
        governance: &signer,
        is_multi_step: bool
    ) acquires VotingForum {
        account::create_account_for_test(@supra_framework);
        timestamp::set_time_has_started_for_testing(supra_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let voters = vector[@0xa1, @0xa2, @0xa3];
        let proposal_id = create_test_proposal_generic(governance, is_multi_step, voters);

        // Vote.
        let proof = TestProposal {};
        vote<TestProposal>(&account::create_signer_for_test(@0xa1), &proof, governance_address, proposal_id, true);
        vote<TestProposal>(&account::create_signer_for_test(@0xa1), &proof, governance_address, proposal_id, false);
        let TestProposal {} = proof;

        // Resolve.
        timestamp::fast_forward_seconds(VOTING_DURATION_SECS + 1);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_FAILED, 1);
        resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, is_multi_step, true);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30002, location = Self)]
    public entry fun test_voting_failed(supra_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_failed_generic(supra_framework, governance, false);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30002, location = Self)]
    public entry fun test_voting_failed_multi_step(supra_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_failed_generic(supra_framework, governance, true);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30005, location = Self)]
    public entry fun test_cannot_vote_after_voting_period_is_over(
        supra_framework: signer,
        governance: signer
    ) acquires VotingForum {
        account::create_account_for_test(@supra_framework);
        timestamp::set_time_has_started_for_testing(&supra_framework);
        let governance_address = signer::address_of(&governance);
        account::create_account_for_test(governance_address);
        let voters = vector[@0xa1, @0xa2, @0xa3];
        let proposal_id = create_test_proposal(&governance, voters);
        // Voting period is over. Voting should now fail.
        timestamp::fast_forward_seconds(VOTING_DURATION_SECS + 1);
        let proof = TestProposal {};
        vote<TestProposal>(&account::create_signer_for_test(@0xa1), &proof, governance_address, proposal_id, true);
        let TestProposal {} = proof;
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30009, location = Self)]
    public entry fun test_cannot_vote_after_multi_step_proposal_starts_executing(
        supra_framework: signer,
        governance: signer
    ) acquires VotingForum {
        account::create_account_for_test(@supra_framework);
        timestamp::set_time_has_started_for_testing(&supra_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(&governance);
        account::create_account_for_test(governance_address);
        let voters = vector[@0xa1, @0xa2, @0xa3];
        let proposal_id = create_test_proposal_generic(&governance, true, voters);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_PENDING, 0);

        // Vote.
        let proof = TestProposal {};
        vote<TestProposal>(&account::create_signer_for_test(@0xa1), &proof, governance_address, proposal_id, true);
        vote<TestProposal>(&account::create_signer_for_test(@0xa2), &proof, governance_address, proposal_id, true);

        // Resolve early.
        timestamp::fast_forward_seconds(1);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_SUCCEEDED, 1);
        resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, true, false);
        vote<TestProposal>(&account::create_signer_for_test(@0xa3), &proof, governance_address, proposal_id, false);
        let TestProposal {} = proof;
    }

    #[test_only]
    public entry fun test_voting_failed_early_generic(
        supra_framework: &signer,
        governance: &signer,
        is_multi_step: bool
    ) acquires VotingForum {
        account::create_account_for_test(@supra_framework);
        timestamp::set_time_has_started_for_testing(supra_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let voters = vector[@0xa1, @0xa2, @0xa3];
        let proposal_id = create_test_proposal_generic(governance, is_multi_step, voters);

        // Vote.
        let proof = TestProposal {};
        vote<TestProposal>(&account::create_signer_for_test(@0xa1), &proof, governance_address, proposal_id, true);
        vote<TestProposal>(&account::create_signer_for_test(@0xa1), &proof, governance_address, proposal_id, false);
        let TestProposal {} = proof;

        // Resolve.
        timestamp::fast_forward_seconds(VOTING_DURATION_SECS + 1);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_FAILED, 1);
        resolve_proposal_for_test<TestProposal>(governance_address, proposal_id, is_multi_step, true);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30002, location = Self)]
    public entry fun test_voting_failed_early(supra_framework: &signer, governance: &signer) acquires VotingForum {
        test_voting_failed_early_generic(supra_framework, governance, true);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    #[expected_failure(abort_code = 0x30002, location = Self)]
    public entry fun test_voting_failed_early_multi_step(
        supra_framework: &signer,
        governance: &signer
    ) acquires VotingForum {
        test_voting_failed_early_generic(supra_framework, governance, false);
    }

    #[test(supra_framework = @supra_framework, governance = @0x123)]
    public entry fun test_replace_execution_hash(supra_framework: &signer, governance: &signer) acquires VotingForum {
        account::create_account_for_test(@supra_framework);
        timestamp::set_time_has_started_for_testing(supra_framework);

        // Register voting forum and create a proposal.
        let governance_address = signer::address_of(governance);
        account::create_account_for_test(governance_address);
        let voters = vector[@0xa1, @0xa2, @0xa3];
        let proposal_id = create_test_proposal_generic(governance, true, voters);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_PENDING, 0);

        // Vote.
        let proof = TestProposal {};
        vote<TestProposal>(&account::create_signer_for_test(@0xa1), &proof, governance_address, proposal_id, true);
        vote<TestProposal>(&account::create_signer_for_test(@0xa2), &proof, governance_address, proposal_id, true);
        let TestProposal {} = proof;

        // Resolve.
        timestamp::fast_forward_seconds(VOTING_DURATION_SECS + 1);
        assert!(get_proposal_state<TestProposal>(governance_address, proposal_id) == PROPOSAL_STATE_SUCCEEDED, 1);

        resolve_proposal_v2<TestProposal>(governance_address, proposal_id, vector[10u8]);
        let voting_forum = borrow_global<VotingForum<TestProposal>>(governance_address);
        let proposal = table::borrow(&voting_forum.proposals, 0);
        assert!(proposal.execution_hash == vector[10u8], 2);
        assert!(!table::borrow(&voting_forum.proposals, proposal_id).is_resolved, 3);
    }
}
