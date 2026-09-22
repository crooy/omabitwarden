# Glossary

Canonical vocabulary for omabitwarden. Skills and docs use these terms exactly.

## Vault

The user's Bitwarden vault, accessed through the official `bw` CLI. Source of truth for all Items.

## Item

One entry in the Vault (e.g. a login, an SSH key, a secure note). Identified by its bw id or a unique search term. Carries typed Fields.

## Field

A typed value on an Item: `username`, `password`, `totp`, `uri`, `notes`, or a custom field (`text` / `hidden` / `boolean`). "Copy a value" always means copying one Field.

## Clipboard

The Wayland clipboard. The user's word "pasteboard" means this. The app writes Field values to it; it never reads from it.

## Unlock / Session Key

Unlocking the Vault yields a bw session key (what `bw unlock --raw` prints). Holding a valid Session Key is the app's "unlocked" state; without one the app is "locked".

## Vault session

The app's Unlock state machine (`VaultSession.qml`): derives the Session Key from the master password, loads the Vault's login Items with one `bw list items` child, and exposes locked/unlocking/ready plus the Items. Owns no rendering; the panel is its only caller.

## Generator

The bitwarden-style secret generator (length, character classes, passphrase mode) used to produce a new secret, independent of any existing Item.
