# カレントディレクトリに .csproj が存在するかチェック
ifneq ($(wildcard *.csproj),)
    # .csproj が存在する場合、.NET ライブラリビルド用 Makefile をinclude
    include $(WORKSPACE_FOLDER)/makefw/makefiles/makelibsrc_dotnet.mk
else
    # .csproj が存在しない場合、C/C++ ライブラリビルド用 Makefile をinclude
    include $(WORKSPACE_FOLDER)/makefw/makefiles/makelibsrc_c_cpp.mk
endif
