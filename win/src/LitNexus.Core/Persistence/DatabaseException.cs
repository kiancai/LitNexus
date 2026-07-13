using System;

namespace LitNexus.Core.Persistence
{
    public sealed class DatabaseException : Exception
    {
        public DatabaseException(string message)
            : base(message)
        {
        }

        public DatabaseException(string message, Exception innerException)
            : base(message, innerException)
        {
        }
    }
}
