"""Minimal account ledger. Balances are stored in integer cents."""

class InsufficientFunds(Exception):
    pass

class Ledger:
    def __init__(self):
        self.balances = {}      # account -> cents
        self.entries = []       # (account, delta_cents, memo)

    def open(self, account, cents=0):
        if account in self.balances:
            raise ValueError("account exists")
        self.balances[account] = 0
        if cents:
            self._post(account, cents, "opening")

    def _post(self, account, delta, memo):
        self.balances[account] += delta
        self.entries.append((account, delta, memo))

    def balance(self, account):
        return self.balances[account]
