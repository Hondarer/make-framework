# カレントディレクトリに .csproj が存在するかチェック
ifneq ($(wildcard *.csproj),)
    # .csproj が存在する場合、.NET 実行体ビルド用 Makefile をinclude
    include $(WORKSPACE_FOLDER)/makefw/makefiles/makesrc_dotnet.mk
else
    # .csproj が存在しない場合、C/C++ 実行体ビルド用 Makefile をinclude
    include $(WORKSPACE_FOLDER)/makefw/makefiles/makesrc_c_cpp.mk
endif
