"""Order pricing helpers. All money values are integer cents."""

def apply_discount(cents, percent):
    """Return the price after taking `percent` off."""
    return cents - int(cents * percent / 100)

def apply_tax(cents, percent):
    """Return the price with `percent` tax added."""
    return cents + int(cents * percent / 100)

def order_total(items, discount_percent=0, tax_percent=0):
    """items: list of (unit_cents, quantity). Discount first, then tax."""
    subtotal = sum(unit * qty for unit, qty in items)
    return apply_tax(apply_discount(subtotal, discount_percent), tax_percent)
