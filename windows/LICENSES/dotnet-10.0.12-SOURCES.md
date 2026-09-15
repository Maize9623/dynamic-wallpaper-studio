# Microsoft .NET 10.0.12 notice sources

The Windows portable release is self-contained and publishes the .NET 10.0.12
runtime and Windows Desktop (WPF) runtime. The build also copies the matching
SDK-root `LICENSE.txt` and `ThirdPartyNotices.txt` into the release `LICENSES`
directory as `dotnet-LICENSE.txt` and `dotnet-ThirdPartyNotices.txt`.

The additional version-pinned files in this directory preserve the content of
the corresponding files in Microsoft's repositories. Line endings and trailing
whitespace may be normalized for this repository:

- `dotnet-wpf-10.0.12-LICENSE.txt`:
  https://github.com/dotnet/wpf/blob/v10.0.12/LICENSE.TXT
- `dotnet-wpf-10.0.12-ThirdPartyNotices.txt`:
  https://github.com/dotnet/wpf/blob/v10.0.12/THIRD-PARTY-NOTICES.TXT
- `dotnet-10.0.12-license-information.md`:
  https://github.com/dotnet/core/blob/v10.0.12/license-information.md
- `dotnet-10.0.12-license-information-windows.md`:
  https://github.com/dotnet/core/blob/v10.0.12/license-information-windows.md

The Windows mapping identifies the Microsoft-specific terms that apply to
`coreclr.dll`, WPF native components, and `D3DCompiler_47_cor3.dll`. Follow the
linked .NET Library License and Windows SDK License for their full terms.
