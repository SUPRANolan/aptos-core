// Copyright © Aptos Foundation
// Parts of the project are originally copyright © Meta Platforms, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::pipeline::pipeline_phase::StatelessPipeline;
use aptos_crypto::ed25519;
use aptos_safety_rules::Error;
use aptos_types::ledger_info::{LedgerInfo, LedgerInfoWithSignatures};
use async_trait::async_trait;
use std::{
    fmt::{Debug, Display, Formatter},
    sync::Arc,
};

/// [ This class is used when consensus.decoupled = true ]
/// SigningPhase is a singleton that receives executed blocks from
/// the buffer manager and sign them. After getting the signature from
/// the safety rule, SigningPhase sends the signature and error (if any) back.

pub struct SigningRequest {
    pub ordered_ledger_info: LedgerInfoWithSignatures,
    pub commit_ledger_info: LedgerInfo,
}

impl Debug for SigningRequest {
    fn fmt(&self, f: &mut Formatter) -> std::fmt::Result {
        write!(f, "{}", self)
    }
}

impl Display for SigningRequest {
    fn fmt(&self, f: &mut Formatter) -> std::fmt::Result {
        write!(
            f,
            "SigningRequest({}, {})",
            self.ordered_ledger_info, self.commit_ledger_info
        )
    }
}

pub trait CommitSignerProvider: Send + Sync {
    fn sign_commit_vote(
        &self,
        ledger_info: LedgerInfoWithSignatures,
        new_ledger_info: LedgerInfo,
    ) -> Result<ed25519::Signature, Error>;
}

pub struct SigningResponse {
    pub signature_result: Result<ed25519::Signature, Error>,
    pub commit_ledger_info: LedgerInfo,
}

pub struct SigningPhase {
    safety_rule_handle: Arc<dyn CommitSignerProvider>,
}

impl SigningPhase {
    pub fn new(safety_rule_handle: Arc<dyn CommitSignerProvider>) -> Self {
        Self { safety_rule_handle }
    }
}

#[async_trait]
impl StatelessPipeline for SigningPhase {
    type Request = SigningRequest;
    type Response = SigningResponse;

    const NAME: &'static str = "signing";

    async fn process(&self, req: SigningRequest) -> SigningResponse {
        let SigningRequest {
            ordered_ledger_info,
            commit_ledger_info,
        } = req;

        SigningResponse {
            signature_result: self
                .safety_rule_handle
                .sign_commit_vote(ordered_ledger_info, commit_ledger_info.clone()),
            commit_ledger_info,
        }
    }
}
