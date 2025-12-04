{ pkgs, ... }: {
  # Use stable Nix package channel
  channel = "stable-24.05";

  # System packages to install
  packages = [
    pkgs.openssh             # Open SSH
    pkgs.python311           # Python 3.11
    pkgs.postgresql_16       # PostgreSQL 16
    pkgs.azure-cli           # Azure CLI
    pkgs.google-cloud-sdk    # Google Cloud SDK (gcloud)
    pkgs.git                 # Git version control
  ];

  # Environment variables
  env = {
    FLASK_APP = "main.py";
    FLASK_ENV = "development";
  };

  # Enable PostgreSQL service
  services.postgres = {
    enable = true;
    package = pkgs.postgresql_16;
    enableTcp = true;
  };

  # Firebase Studio configuration
  idx = {
    # VS Code extensions
    extensions = [
      "google.gemini-cli-vscode-ide-companion"
      "ms-python.python"
      "ms-python.vscode-pylance"
    ];

    # Workspace lifecycle hooks
    workspace = {
      onCreate = {
        default.openFiles = [ ".idx/dev.nix" "README.md" ];
      };
    };

    # Preview configuration
    previews = {
      enable = true;
      previews = {
        web = {
          command = ["python3" "-m" "http.server" "$PORT" "--bind" "0.0.0.0"];
          manager = "web";
        };
      };
    };
  };
}
