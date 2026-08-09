"""凭据脱敏单元测试 — 收紧的正则、共现模式、整文件跳过判定（r1 P2.10）"""

import pytest
from kb.utils import desensitize, is_sensitive_file


class TestSensitiveDetection:
    """r1 收紧版凭据检测逻辑。"""

    def test_password_main_pattern(self):
        """主模式：密码字段 + 长值 → 脱敏。"""
        text, count = desensitize("密码=mySecretPassw0rd!")
        assert "[已脱敏]" in text
        assert count >= 1

    def test_cooccurrence_mode(self):
        """共现模式：账号与密码共现才触发。"""
        # 单独出现账号 → 不脱敏
        text, count = desensitize("订单账号=HT260721001")
        assert "[已脱敏]" not in text
        assert count == 0

        # 账号 + 密码共现 → 整个共现区域脱敏
        text, count = desensitize(
            "登录账号=admin\n登录密码=P@ssw0rd123"
        )
        assert "[已脱敏]" in text
        assert "登录账号" not in text and "登录密码" not in text

    def test_short_password_not_matched(self):
        """短值（<8字符）不满足主模式长度要求。"""
        text, count = desensitize("密码=123456")
        # 主模式要求 ≥8 字符，这个只有 6 位
        assert count == 0

    def test_business_account_not_false_positive(self):
        """业务数据中的"客户账号"不误伤。"""
        text, count = desensitize(
            "客户账号=CUS001234\n"
            "订单金额=5000.00\n"
            "状态=已出票"
        )
        assert "[已脱敏]" not in text
        assert count == 0

    def test_is_sensitive_high_count(self):
        """单文件脱敏超阈值 → 标记敏感。"""
        assert is_sensitive_file(desensitize_count=5) is True

    def test_is_sensitive_env_hint(self):
        """路径含实操环境特征 → 标记敏感。"""
        assert is_sensitive_file(desensitize_count=1, path_hint="实操环境.md") is True
        assert is_sensitive_file(desensitize_count=1, path_hint="source.txt") is True

    def test_is_sensitive_normal_below_threshold(self):
        """低脱敏次数 + 无特殊路径 → 不标记敏感。"""
        assert is_sensitive_file(desensitize_count=1) is False
        assert is_sensitive_file(desensitize_count=2) is False
        assert is_sensitive_file(desensitize_count=3) is False  # 边界：>3 才触发

    def test_appid_without_secret_no_match(self):
        """appid 单独出现且无 secret 共现 → 不脱敏。"""
        text, count = desensitize("appid=wx1234567890abcdef")
        assert count == 0

    def test_appid_with_secret_cooccur(self):
        """appid + secret 共现 → 命中。"""
        text, count = desensitize("appid=wx123\nsecret_key=sk_abc123def456")
        assert count >= 1
