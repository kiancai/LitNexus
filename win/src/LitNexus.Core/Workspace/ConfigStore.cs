using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json.Serialization;
using LitNexus.Core.Domain;
using Tomlyn;

namespace LitNexus.Core.Workspace
{
    /// <summary>
    /// Read/write failures for the portable project configuration. Callers can
    /// show the message directly and keep the currently opened workspace intact.
    /// </summary>
    public sealed class ConfigStoreException : Exception
    {
        public ConfigStoreException(string message)
            : base(message)
        {
        }

        public ConfigStoreException(string message, Exception innerException)
            : base(message, innerException)
        {
        }
    }

    /// <summary>
    /// Typed TOML persistence for litnexus.toml. JsonPropertyName attributes on
    /// the domain models define the cross-platform on-disk keys; no Windows-only
    /// config format or environment-variable override exists here.
    /// </summary>
    public static class ConfigStore
    {
        public static AppConfig Load(string configPath)
        {
            if (string.IsNullOrWhiteSpace(configPath))
            {
                throw new ArgumentException("必须提供 litnexus.toml 路径。", nameof(configPath));
            }

            string fullPath = Path.GetFullPath(configPath);
            if (!File.Exists(fullPath))
            {
                throw new ConfigStoreException("配置文件不存在：" + fullPath);
            }

            try
            {
                string content = File.ReadAllText(fullPath, Encoding.UTF8);
                return Deserialize(content, Path.GetDirectoryName(fullPath));
            }
            catch (ConfigStoreException)
            {
                throw;
            }
            catch (Exception exception)
            {
                throw new ConfigStoreException("无法读取配置文件：" + fullPath, exception);
            }
        }

        public static AppConfig Load(WorkspacePaths workspace)
        {
            if (workspace == null)
            {
                throw new ArgumentNullException(nameof(workspace));
            }

            return Load(workspace.ConfigPath);
        }

        /// <summary>
        /// Parses configuration content. workspaceRoot is optional and is used
        /// solely for the documented one-way fallback from legacy list files when
        /// the corresponding TOML key is absent; it is never inferred from an
        /// environment variable or implicit active project.
        /// </summary>
        public static AppConfig Deserialize(string toml, string? workspaceRoot = null)
        {
            if (toml == null)
            {
                throw new ArgumentNullException(nameof(toml));
            }

            try
            {
                AppConfig? config = TomlSerializer.Deserialize<AppConfig>(toml);
                if (config == null)
                {
                    throw new ConfigStoreException("配置文件没有可读取的 TOML 内容。");
                }

                ConfigPresenceProbe? presence = TomlSerializer.Deserialize<ConfigPresenceProbe>(toml);
                config.Normalize();
                ApplyLegacyCompatibility(config, presence, workspaceRoot);
                config.Normalize();
                return config;
            }
            catch (ConfigStoreException)
            {
                throw;
            }
            catch (Exception exception)
            {
                throw new ConfigStoreException("配置文件 TOML 语法或字段类型错误：" + exception.Message, exception);
            }
        }

        public static string Serialize(AppConfig config)
        {
            if (config == null)
            {
                throw new ArgumentNullException(nameof(config));
            }

            config.Normalize();
            try
            {
                return TomlSerializer.Serialize(config);
            }
            catch (Exception exception)
            {
                throw new ConfigStoreException("无法序列化项目配置。", exception);
            }
        }

        public static void Save(AppConfig config, string configPath)
        {
            if (string.IsNullOrWhiteSpace(configPath))
            {
                throw new ArgumentException("必须提供 litnexus.toml 路径。", nameof(configPath));
            }

            string fullPath = Path.GetFullPath(configPath);
            string? parent = Path.GetDirectoryName(fullPath);
            if (string.IsNullOrEmpty(parent))
            {
                throw new ConfigStoreException("无法确定配置文件目录：" + fullPath);
            }

            string serialized = Serialize(config);
            try
            {
                Directory.CreateDirectory(parent);
                WriteAtomically(fullPath, serialized);
            }
            catch (ConfigStoreException)
            {
                throw;
            }
            catch (Exception exception)
            {
                throw new ConfigStoreException("无法保存配置文件：" + fullPath, exception);
            }
        }

        public static void Save(AppConfig config, WorkspacePaths workspace)
        {
            if (workspace == null)
            {
                throw new ArgumentNullException(nameof(workspace));
            }

            Save(config, workspace.ConfigPath);
        }

        private static void ApplyLegacyCompatibility(
            AppConfig config,
            ConfigPresenceProbe? presence,
            string? workspaceRoot)
        {
            if (string.IsNullOrWhiteSpace(workspaceRoot))
            {
                ApplyLegacyAiProfile(config, presence);
                return;
            }

            WorkspacePaths workspace = WorkspacePaths.ForRoot(workspaceRoot!);
            DownloadPresenceProbe? downloadPresence = presence == null ? null : presence.Download;

            // An explicit empty TOML array is meaningful and must not be replaced
            // by old files. Only a missing key uses the documented compatibility
            // fallback.
            if (downloadPresence == null || downloadPresence.Journals == null)
            {
                string? journals = ReadLegacyFileIfPresent(workspace.JournalsFile);
                if (journals != null)
                {
                    config.Download.Journals = SplitLines(journals);
                }
            }

            if (downloadPresence == null || downloadPresence.Keywords == null)
            {
                List<string> legacyKeywordLines = new List<string>();
                foreach (string file in workspace.LegacyKeywordFiles)
                {
                    string? keywordContent = ReadLegacyFileIfPresent(file);
                    if (keywordContent != null)
                    {
                        legacyKeywordLines.AddRange(SplitLines(keywordContent));
                    }
                }

                if (legacyKeywordLines.Count > 0)
                {
                    config.Download.Keywords = legacyKeywordLines;
                }
            }

            ApplyLegacyAiProfile(config, presence);
        }

        private static void ApplyLegacyAiProfile(AppConfig config, ConfigPresenceProbe? presence)
        {
            if (config.AI.Profiles.Count > 0 || presence == null || presence.Ai == null)
            {
                return;
            }

            string baseUrl = presence.Ai.LegacyBaseUrl ?? string.Empty;
            string model = presence.Ai.LegacyModel ?? string.Empty;
            string apiKey = presence.Ai.LegacyApiKey ?? string.Empty;
            if (string.IsNullOrWhiteSpace(baseUrl)
                && string.IsNullOrWhiteSpace(model)
                && string.IsNullOrWhiteSpace(apiKey))
            {
                return;
            }

            var profile = new AIProfile
            {
                Name = "默认",
                BaseUrl = baseUrl,
                Model = model,
                ApiKey = apiKey,
                ExtraParams = presence.Ai.LegacyExtraParams ?? string.Empty,
            };
            profile.Normalize();
            config.AI.Profiles.Add(profile);
            if (string.IsNullOrWhiteSpace(config.AI.Active))
            {
                config.AI.Active = profile.Id;
            }
        }

        private static string? ReadLegacyFileIfPresent(string path)
        {
            return File.Exists(path) ? File.ReadAllText(path, Encoding.UTF8) : null;
        }

        private static List<string> SplitLines(string text)
        {
            // A terminal newline is a formatting detail, not an extra configured
            // journal/query. StringReader also handles legacy CRLF files cleanly.
            using (var reader = new StringReader(text))
            {
                var result = new List<string>();
                string? line;
                while ((line = reader.ReadLine()) != null)
                {
                    result.Add(line);
                }

                return result;
            }
        }

        private static void WriteAtomically(string destination, string content)
        {
            string temporary = destination + ".tmp-" + Guid.NewGuid().ToString("N");
            try
            {
                File.WriteAllText(temporary, content, new UTF8Encoding(false));
                if (!File.Exists(destination))
                {
                    File.Move(temporary, destination);
                    return;
                }

                // Do not fall back to delete-then-move: if a network share or a
                // locked file cannot provide replacement semantics, retaining the
                // known-good old config is safer than risking a half replacement.
                File.Replace(temporary, destination, null);
            }
            finally
            {
                if (File.Exists(temporary))
                {
                    File.Delete(temporary);
                }
            }
        }

        /// <summary>
        /// A small typed secondary parse used only to distinguish an absent array
        /// from an explicit empty one and to migrate the pre-profile AI format.
        /// This avoids a hand-rolled TOML parser while keeping the public model
        /// fully typed through Tomlyn + JsonPropertyName.
        /// </summary>
        private sealed class ConfigPresenceProbe
        {
            [JsonPropertyName("download")]
            public DownloadPresenceProbe? Download { get; set; }

            [JsonPropertyName("ai")]
            public AiPresenceProbe? Ai { get; set; }
        }

        private sealed class DownloadPresenceProbe
        {
            [JsonPropertyName("journals")]
            public List<string>? Journals { get; set; }

            [JsonPropertyName("keywords")]
            public List<string>? Keywords { get; set; }
        }

        private sealed class AiPresenceProbe
        {
            [JsonPropertyName("base_url")]
            public string? LegacyBaseUrl { get; set; }

            [JsonPropertyName("model")]
            public string? LegacyModel { get; set; }

            [JsonPropertyName("api_key")]
            public string? LegacyApiKey { get; set; }

            [JsonPropertyName("extra_params")]
            public string? LegacyExtraParams { get; set; }
        }
    }
}
