# ADR-0005 · Product name is Dhaaga; branding does not reach technical identifiers

**Status** Accepted · 26 Aug 2026 · decided by RayHaan

## Context
The product was drafted under the working codename "Karigar". The Product Owner
created the Flutter project as `dhaaga` — Hindi and Urdu for *thread* — and has
now confirmed it as the permanent name with the positioning line
"Dhaaga — The Operating System for the Modern Tailoring Business."

A rename can be scoped two ways: product-facing surfaces only, or everything
including identifiers, package names, database objects and infrastructure.

## Decision
The name is **Dhaaga**, permanently. The rename applies to product-facing
surfaces: documentation, README, UI text, store listings and configuration a
person reads.

It does **not** apply to technical identifiers, package names, database objects
or infrastructure resources renamed for branding alone. Those already carry the
name from the earlier rename and are left as they are.

## Consequences
* One name everywhere a person can see it.
* No churn in migrations, schema names or environment variables for cosmetic
  reasons — renaming a database object is a migration, and a migration exists to
  change behaviour, not spelling.
* If a technical identifier ever needs to change for a real reason, it changes
  then, on its own merits.
