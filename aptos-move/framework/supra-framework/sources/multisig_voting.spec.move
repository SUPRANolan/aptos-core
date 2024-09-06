spec supra_framework::multisig_voting {

    spec module {
        pragma verify = false;
    }

    spec fun spec_get_proposal_expiration_secs<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): u64 {
        let voting_forum = global<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::spec_get(voting_forum.proposals, proposal_id);
        proposal.expiration_secs
    }

}
