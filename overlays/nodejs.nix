final: prev: {
  # Pin nodejs version or apply customizations
  nodejs = prev.nodejs_latest;
  
  # Add any other Node.js related overrides here
  nodePackages = prev.nodePackages // {
    # Override specific node packages if needed
  };
}