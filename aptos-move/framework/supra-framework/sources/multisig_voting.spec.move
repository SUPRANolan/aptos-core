spec supra_framework::multisig_voting {

    spec module {
        pragma verify = true;
    }

    spec register {

    }

    spec create_proposal {

    }

    spec create_proposal_v2 {

    }

    spec vote {}

    spec is_proposal_resolvable {}

    spec resolve {}

    spec resolve_proposal_v2 {}

    spec next_proposal_id {}

    spec get_proposer {}

    spec is_voting_closed {}

    spec can_be_resolved_early {}

    spec get_proposal_metadata {}

    spec get_proposal_metadata_value {}

    spec get_proposal_state {}

    spec get_proposal_creation_secs {}

    spec get_proposal_expiration_secs {}

    spec get_execution_hash {}

    spec get_min_vote_threshold {}

    spec get_votes {}

    spec is_resolved {}

    spec get_resolution_time_secs {}

    spec is_multi_step_proposal_in_execution {}

    spec is_voting_period_over {}

    spec fun spec_get_proposal_expiration_secs<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): u64 {
        let voting_forum = global<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::spec_get(voting_forum.proposals, proposal_id);
        proposal.expiration_secs
    }

}
