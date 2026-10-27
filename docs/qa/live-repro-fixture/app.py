def discount_total(price, quantity, discount):
    """Return a discounted total; fixture intentionally omits quantity validation."""
    return price * quantity * (1 - discount)
