import Foundation

/// Instaluje „Szybkie akcje" Findera do konwersji obrazów bez otwierania aplikacji.
///
/// Każda akcja to bundle `*.workflow` (usługa Automatora) w `~/Library/Services`.
/// Po kliknięciu pliku prawym przyciskiem → „Szybkie akcje" → „Konwertuj na JPG/PNG (Skryba)"
/// macOS uruchamia osadzone `skryba-cli image --to <fmt> --beside-source "$@"` w tle.
public enum FinderQuickAction {

    public struct Definition: Sendable {
        public let title: String
        public let format: String   // "jpg" albo "png"
    }

    public static let definitions: [Definition] = [
        Definition(title: "Konwertuj na JPG (Skryba)", format: "jpg"),
        Definition(title: "Konwertuj na PNG (Skryba)", format: "png"),
    ]

    /// Domyślny katalog usług użytkownika (`~/Library/Services`).
    public static var servicesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Services", isDirectory: true)
    }

    static func bundleURL(for def: Definition, in servicesDir: URL) -> URL {
        servicesDir.appendingPathComponent("\(def.title).workflow", isDirectory: true)
    }

    /// Czy obie akcje są zainstalowane.
    public static func isInstalled(in servicesDir: URL? = nil) -> Bool {
        let dir = servicesDir ?? servicesDirectory
        return definitions.allSatisfy {
            FileManager.default.fileExists(atPath: bundleURL(for: $0, in: dir)
                .appendingPathComponent("Contents/document.wflow").path)
        }
    }

    /// Instaluje obie akcje, wpisując do skryptu ścieżkę `cliPath`. Zwraca ścieżki bundli.
    @discardableResult
    public static func install(cliPath: String, to servicesDir: URL? = nil) throws -> [URL] {
        let dir = servicesDir ?? servicesDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var result: [URL] = []
        for def in definitions {
            let bundle = bundleURL(for: def, in: dir)
            let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
            // Świeża instalacja: usuń poprzedni bundle, jeśli istnieje.
            try? FileManager.default.removeItem(at: bundle)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try infoPlist(title: def.title).data(using: .utf8)!
                .write(to: contents.appendingPathComponent("Info.plist"))
            try workflow(format: def.format, cliPath: cliPath).data(using: .utf8)!
                .write(to: contents.appendingPathComponent("document.wflow"))
            result.append(bundle)
        }
        refreshServices()
        return result
    }

    /// Usuwa obie akcje.
    public static func uninstall(from servicesDir: URL? = nil) throws {
        let dir = servicesDir ?? servicesDirectory
        for def in definitions {
            let bundle = bundleURL(for: def, in: dir)
            if FileManager.default.fileExists(atPath: bundle.path) {
                try FileManager.default.removeItem(at: bundle)
            }
        }
        refreshServices()
    }

    /// Odświeża rejestr usług macOS (best-effort — brak `pbs` nie jest błędem instalacji).
    private static func refreshServices() {
        let pbs = "/System/Library/CoreServices/pbs"
        guard FileManager.default.isExecutableFile(atPath: pbs) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pbs)
        p.arguments = ["-flush"]
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: - Generowanie plików bundla

    static func infoPlist(title: String) -> String {
        let t = xmlEscape(title)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>NSServices</key>
        	<array>
        		<dict>
        			<key>NSMenuItem</key>
        			<dict>
        				<key>default</key>
        				<string>\(t)</string>
        			</dict>
        			<key>NSMessage</key>
        			<string>runWorkflowAsService</string>
        			<key>NSRequiredContext</key>
        			<dict>
        				<key>NSApplicationIdentifier</key>
        				<string>com.apple.finder</string>
        			</dict>
        			<key>NSSendFileTypes</key>
        			<array>
        				<string>public.image</string>
        			</array>
        		</dict>
        	</array>
        </dict>
        </plist>
        """
    }

    static func workflow(format: String, cliPath: String) -> String {
        let script = """
        for f in "$@"
        do
          \(shellQuote(cliPath)) image --to \(format) --beside-source "$f"
        done
        """
        let cmd = xmlEscape(script)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>AMApplicationBuild</key>
        	<string>523</string>
        	<key>AMApplicationVersion</key>
        	<string>2.10</string>
        	<key>AMDocumentVersion</key>
        	<string>2</string>
        	<key>actions</key>
        	<array>
        		<dict>
        			<key>action</key>
        			<dict>
        				<key>AMAccepts</key>
        				<dict>
        					<key>Container</key>
        					<string>List</string>
        					<key>Optional</key>
        					<true/>
        					<key>Types</key>
        					<array>
        						<string>com.apple.cocoa.string</string>
        					</array>
        				</dict>
        				<key>AMActionVersion</key>
        				<string>2.0.3</string>
        				<key>AMApplication</key>
        				<array>
        					<string>Automator</string>
        				</array>
        				<key>AMParameterProperties</key>
        				<dict>
        					<key>COMMAND_STRING</key>
        					<dict/>
        					<key>CheckedForUserDefaultShell</key>
        					<dict/>
        					<key>inputMethod</key>
        					<dict/>
        					<key>shell</key>
        					<dict/>
        					<key>source</key>
        					<dict/>
        				</dict>
        				<key>AMProvides</key>
        				<dict>
        					<key>Container</key>
        					<string>List</string>
        					<key>Types</key>
        					<array>
        						<string>com.apple.cocoa.string</string>
        					</array>
        				</dict>
        				<key>ActionBundlePath</key>
        				<string>/System/Library/Automator/Run Shell Script.action</string>
        				<key>ActionName</key>
        				<string>Run Shell Script</string>
        				<key>ActionParameters</key>
        				<dict>
        					<key>COMMAND_STRING</key>
        					<string>\(cmd)</string>
        					<key>CheckedForUserDefaultShell</key>
        					<true/>
        					<key>inputMethod</key>
        					<integer>1</integer>
        					<key>shell</key>
        					<string>/bin/zsh</string>
        					<key>source</key>
        					<string></string>
        				</dict>
        				<key>BundleIdentifier</key>
        				<string>com.apple.RunShellScript</string>
        				<key>CFBundleVersion</key>
        				<string>2.0.3</string>
        				<key>CanShowSelectedItemsWhenRun</key>
        				<false/>
        				<key>CanShowWhenRun</key>
        				<true/>
        				<key>Category</key>
        				<array>
        					<string>AMCategoryUtilities</string>
        				</array>
        				<key>Class Name</key>
        				<string>RunShellScriptAction</string>
        				<key>InputUUID</key>
        				<string>A1B2C3D4-0001-0001-0001-000000000001</string>
        				<key>Keywords</key>
        				<array>
        					<string>Shell</string>
        					<string>Script</string>
        					<string>Command</string>
        					<string>Run</string>
        					<string>Unix</string>
        				</array>
        				<key>OutputUUID</key>
        				<string>A1B2C3D4-0001-0001-0001-000000000002</string>
        				<key>UUID</key>
        				<string>A1B2C3D4-0001-0001-0001-000000000003</string>
        				<key>UnlocalizedApplications</key>
        				<array>
        					<string>Automator</string>
        				</array>
        				<key>arguments</key>
        				<dict>
        					<key>0</key>
        					<dict>
        						<key>default value</key>
        						<integer>0</integer>
        						<key>name</key>
        						<string>inputMethod</string>
        						<key>required</key>
        						<string>0</string>
        						<key>type</key>
        						<string>0</string>
        						<key>uuid</key>
        						<string>0</string>
        					</dict>
        					<key>1</key>
        					<dict>
        						<key>default value</key>
        						<false/>
        						<key>name</key>
        						<string>CheckedForUserDefaultShell</string>
        						<key>required</key>
        						<string>0</string>
        						<key>type</key>
        						<string>0</string>
        						<key>uuid</key>
        						<string>1</string>
        					</dict>
        					<key>2</key>
        					<dict>
        						<key>default value</key>
        						<string></string>
        						<key>name</key>
        						<string>source</string>
        						<key>required</key>
        						<string>0</string>
        						<key>type</key>
        						<string>0</string>
        						<key>uuid</key>
        						<string>2</string>
        					</dict>
        					<key>3</key>
        					<dict>
        						<key>default value</key>
        						<string>/bin/sh</string>
        						<key>name</key>
        						<string>shell</string>
        						<key>required</key>
        						<string>0</string>
        						<key>type</key>
        						<string>0</string>
        						<key>uuid</key>
        						<string>3</string>
        					</dict>
        					<key>4</key>
        					<dict>
        						<key>default value</key>
        						<string></string>
        						<key>name</key>
        						<string>COMMAND_STRING</string>
        						<key>required</key>
        						<string>0</string>
        						<key>type</key>
        						<string>0</string>
        						<key>uuid</key>
        						<string>4</string>
        					</dict>
        				</dict>
        				<key>isViewVisible</key>
        				<integer>1</integer>
        				<key>location</key>
        				<string>309.000000:253.000000</string>
        				<key>nibPath</key>
        				<string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
        			</dict>
        			<key>isViewVisible</key>
        			<integer>1</integer>
        		</dict>
        	</array>
        	<key>connectors</key>
        	<dict/>
        	<key>workflowMetaData</key>
        	<dict>
        		<key>applicationBundleIDsByPath</key>
        		<dict/>
        		<key>applicationPaths</key>
        		<array/>
        		<key>inputTypeIdentifier</key>
        		<string>com.apple.Automator.fileSystemObject</string>
        		<key>outputTypeIdentifier</key>
        		<string>com.apple.Automator.nothing</string>
        		<key>presentationMode</key>
        		<integer>11</integer>
        		<key>processesInput</key>
        		<integer>0</integer>
        		<key>serviceApplicationBundleID</key>
        		<string>com.apple.finder</string>
        		<key>serviceApplicationPath</key>
        		<string>/System/Library/CoreServices/Finder.app</string>
        		<key>serviceInputTypeIdentifier</key>
        		<string>com.apple.Automator.fileSystemObject</string>
        		<key>serviceOutputTypeIdentifier</key>
        		<string>com.apple.Automator.nothing</string>
        		<key>systemImageName</key>
        		<string>NSActionTemplate</string>
        		<key>useAutomaticInputType</key>
        		<integer>0</integer>
        		<key>workflowTypeIdentifier</key>
        		<string>com.apple.Automator.servicesMenu</string>
        	</dict>
        </dict>
        </plist>
        """
    }

    // MARK: - Escapowanie

    static func xmlEscape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }

    /// Cytowanie ścieżki dla powłoki: `'...'` z obsługą apostrofu w ścieżce.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
