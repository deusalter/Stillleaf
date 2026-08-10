import Foundation
import BooksCore
import BooksPlatform
let importer = EPUBPublicationImporter(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
do { let result=try importer.importPublication(from:URL(fileURLWithPath:CommandLine.arguments[1]));print("ACCEPT \(result.publication.id) duplicate=\(result.alreadyImported) spine=\(result.publication.spine)") } catch { print("REJECT \(error.localizedDescription)"); exit(2) }
