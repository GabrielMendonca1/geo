"""
Path-safe workspace key for an issue identifier.

Ports `sanitizeWorkspaceKey` from
Geo/Features/Agent/Data/AgentWorkspaceManager.swift (~L2878):

    private func sanitizeWorkspaceKey(_ identifier: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return String(identifier.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : Character("_")
        })
    }

Phase 1B divergence: this port lowercases the result, so existing case-mixed
workspace dirs under ~/.symphony/workspaces/ created by the Swift manager need
a one-time rename (or `case_sensitive=True` here for backward compat). The
lowercase form is the agreed convention going forward.
"""

import string

_ALLOWED: frozenset[str] = frozenset(
    string.ascii_letters + string.digits + "._-"
)


def sanitize(identifier: str, *, case_sensitive: bool = False) -> str:
    out = "".join(ch if ch in _ALLOWED else "_" for ch in identifier)
    return out if case_sensitive else out.lower()
