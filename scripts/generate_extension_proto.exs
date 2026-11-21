Code.require_file("lib/extension_proto.exs", __DIR__)

{opts, args, invalid} = OptionParser.parse(System.argv(), strict: [check: :boolean])

if args != [] or invalid != [] do
  Mix.raise("Usage: mix run --no-start scripts/generate_extension_proto.exs [--check]")
end

Zaq.Scripts.ExtensionProto.run(opts)
