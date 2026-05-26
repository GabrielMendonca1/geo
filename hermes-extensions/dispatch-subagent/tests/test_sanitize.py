from dispatch_subagent.sanitize import sanitize


def test_lowercase_alphanumeric_passthrough():
    assert sanitize("abc123") == "abc123"


def test_uppercase_gets_lowercased():
    assert sanitize("GEO-123") == "geo-123"


def test_slash_replaced_with_underscore():
    assert sanitize("feat/new-thing") == "feat_new-thing"


def test_dot_dash_underscore_preserved():
    assert sanitize("a.b-c_d") == "a.b-c_d"


def test_spaces_and_specials_collapse_to_underscore():
    assert sanitize("hello world!") == "hello_world_"


def test_unicode_gets_underscored():
    assert sanitize("café") == "caf_"


def test_case_sensitive_flag_preserves_case():
    assert sanitize("GEO-123", case_sensitive=True) == "GEO-123"


def test_empty_string():
    assert sanitize("") == ""
