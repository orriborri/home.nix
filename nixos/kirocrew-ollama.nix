{ pkgs, ... }:

# NixOS module: a local Ollama embedding server for Pasta.
#
# Pasta's kb pipeline embeds records with Ollama by default:
#   endpoint  http://localhost:11434/api/embed   (crates/kb-storage/src/embedder.rs)
#   model     nomic-embed-text  (768-dim)
# unless OPENAI_API_KEY is set. The pasta system user is deliberately
# credential-free, so OpenAI is not an option here — the embedder must be a
# local, self-contained service.
#
# Without this, `kb sync --source vault` still writes the FTS/Tantivy keyword
# index (so keyword search works), but the embedding step cannot reach an
# endpoint and vector search runs on stale/absent vectors. Running Ollama
# locally makes vault indexing fully self-contained and keeps the LanceDB
# vector store fresh on every pasta-vault-index run.
#
# The instance is Graviton (aarch64, no GPU), so the CPU package is used.
# nomic-embed-text is small (~274 MB) and embeds comfortably on CPU.
{
  services.ollama = {
    enable = true;
    # Graviton has no GPU; use the CPU build explicitly.
    package = pkgs.ollama;
    # Defaults to 127.0.0.1:11434, which is exactly what pasta's embedder
    # targets (OLLAMA_URL). Kept explicit so the loopback binding is obvious
    # and never accidentally widened.
    host = "127.0.0.1";
    port = 11434;
    # Pull the embedding model declaratively at activation so it is present
    # before the first pasta-vault-index run. Matches OLLAMA_MODEL in pasta.
    loadModels = [ "nomic-embed-text" ];
  };
}
