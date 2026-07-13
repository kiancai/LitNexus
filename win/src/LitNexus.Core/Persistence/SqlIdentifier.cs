using System;

namespace LitNexus.Core.Persistence
{
    /// <summary>
    /// SQLite parameters cannot stand in for table or column names.  Keep every
    /// identifier that is interpolated into schema SQL inside this deliberately
    /// small grammar.
    /// </summary>
    public static class SqlIdentifier
    {
        public static bool IsValid(string value)
        {
            if (string.IsNullOrEmpty(value))
            {
                return false;
            }

            if (!(IsAsciiLetter(value[0]) || value[0] == '_'))
            {
                return false;
            }

            for (var index = 1; index < value.Length; index++)
            {
                var character = value[index];
                if (!(IsAsciiLetter(character) || IsAsciiDigit(character) || character == '_'))
                {
                    return false;
                }
            }

            return true;
        }

        private static bool IsAsciiLetter(char value)
        {
            return (value >= 'A' && value <= 'Z') || (value >= 'a' && value <= 'z');
        }

        private static bool IsAsciiDigit(char value)
        {
            return value >= '0' && value <= '9';
        }

        public static string Quote(string value)
        {
            if (!IsValid(value))
            {
                throw new ArgumentException("SQLite 标识符只能包含字母、数字和下划线，且不能以数字开头。", nameof(value));
            }

            return "\"" + value + "\"";
        }

        public static void Require(string value, string parameterName)
        {
            if (!IsValid(value))
            {
                throw new ArgumentException("SQLite 标识符只能包含字母、数字和下划线，且不能以数字开头。", parameterName);
            }
        }
    }
}
