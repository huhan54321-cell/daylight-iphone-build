// Dependency-free project generator. Run again after adding native source files.
const fs = require('node:fs');
const path = require('node:path');
const base = path.resolve(__dirname, '../ios');
const repository = process.env.GITHUB_REPOSITORY;
if (repository && /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) {
  const info = path.join(base, 'Daylight/Info.plist');
  let xml = fs.readFileSync(info, 'utf8').replace(/<key>CareerPublicFeedURL<\/key><string>[^<]*<\/string>/g, '');
  xml = xml.replace('</dict></plist>', `<key>CareerPublicFeedURL</key><string>https://raw.githubusercontent.com/${repository}/main/public/career-feed.json</string></dict></plist>`);
  fs.writeFileSync(info, xml);
}

const files = fs.readdirSync(path.join(base, 'Daylight')).filter(f => f.endsWith('.swift')).sort();
const testFolder = path.join(base, 'DaylightUITests');
const testFiles = fs.existsSync(testFolder) ? fs.readdirSync(testFolder).filter(f => f.endsWith('.swift')).sort() : [];
const id = (group, n) => group + n.toString(16).toUpperCase().padStart(22, '0');
const project='AA0000000000000000000001', main='AA0000000000000000000002', source='AA0000000000000000000003', products='AA0000000000000000000004', product='AA0000000000000000000005', target='AA0000000000000000000006', sources='AA0000000000000000000007', frameworks='AA0000000000000000000008', resources='AA0000000000000000000009', projList='AA000000000000000000000A', targetList='AA000000000000000000000B';
const debug='AA000000000000000000000C', release='AA000000000000000000000D', targetDebug='AA000000000000000000000E', targetRelease='AA000000000000000000000F', info='AA0000000000000000000010', entitlements='AA0000000000000000000011';
const nativeSettings = `CODE_SIGN_STYLE = Automatic; CODE_SIGN_ENTITLEMENTS = Daylight/Daylight.entitlements; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = Daylight/Info.plist; IPHONEOS_DEPLOYMENT_TARGET = 17.0; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks"); PRODUCT_BUNDLE_IDENTIFIER = com.personalassistant.Daylight; PRODUCT_NAME = "$(TARGET_NAME)"; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; SUPPORTS_MACCATALYST = NO; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = 1;`;
const assetRef='AA0000000000000000000012', assetBuild='AA0000000000000000000013', privacyRef='AA0000000000000000000014', privacyBuild='AA0000000000000000000015';
const careerSeedRef='AA0000000000000000000016', careerSeedBuild='AA0000000000000000000017';
const completeNativeSettings = nativeSettings + ' ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;';
const testGroup='AD0000000000000000000001', testProduct='AD0000000000000000000002', testTarget='AD0000000000000000000003', testSources='AD0000000000000000000004', testFrameworks='AD0000000000000000000005', testResources='AD0000000000000000000006', testList='AD0000000000000000000007', testDebug='AD0000000000000000000008', testRelease='AD0000000000000000000009', testProxy='AD000000000000000000000A', testDependency='AD000000000000000000000B';
const testSettings = `CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"); PRODUCT_BUNDLE_IDENTIFIER = com.personalassistant.DaylightUITests; PRODUCT_NAME = "$(TARGET_NAME)"; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = "iphonesimulator"; SUPPORTS_MACCATALYST = NO; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = 1; TEST_TARGET_NAME = Daylight;`;
const objects = [
  ...files.map((f,i)=>`${id('AB',i+1)} /* ${f} in Sources */ = {isa = PBXBuildFile; fileRef = ${id('AC',i+1)} /* ${f} */; };`),
  ...files.map((f,i)=>`${id('AC',i+1)} /* ${f} */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ${f}; sourceTree = "<group>"; };`),
  ...testFiles.map((f,i)=>`${id('AE',i+1)} /* ${f} in Sources */ = {isa = PBXBuildFile; fileRef = ${id('AF',i+1)} /* ${f} */; };`),
  ...testFiles.map((f,i)=>`${id('AF',i+1)} /* ${f} */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ${f}; sourceTree = "<group>"; };`),
  `${info} = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };`,
  `${entitlements} = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Daylight.entitlements; sourceTree = "<group>"; };`,
  `${assetRef} = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };`,
  `${privacyRef} = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; };`,
  `${careerSeedRef} = {isa = PBXFileReference; lastKnownFileType = text.json; path = CareerSeed.json; sourceTree = "<group>"; };`,
  `${assetBuild} = {isa = PBXBuildFile; fileRef = ${assetRef}; };`,
  `${privacyBuild} = {isa = PBXBuildFile; fileRef = ${privacyRef}; };`,
  `${careerSeedBuild} = {isa = PBXBuildFile; fileRef = ${careerSeedRef}; };`,
  `${product} = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Daylight.app; sourceTree = BUILT_PRODUCTS_DIR; };`,
  `${testProduct} = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = DaylightUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };`,
  `${main} = {isa = PBXGroup; children = (${source}, ${testGroup}, ${products}); sourceTree = "<group>"; };`,
  `${source} = {isa = PBXGroup; children = (${files.map((f,i)=>id('AC',i+1)).join(', ')}, ${info}, ${entitlements}, ${assetRef}, ${privacyRef}, ${careerSeedRef}); path = Daylight; sourceTree = "<group>"; };`,
  `${testGroup} = {isa = PBXGroup; children = (${testFiles.map((f,i)=>id('AF',i+1)).join(', ')}); path = DaylightUITests; sourceTree = "<group>"; };`,
  `${products} = {isa = PBXGroup; children = (${product}, ${testProduct}); name = Products; sourceTree = "<group>"; };`,
  `${sources} = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (${files.map((f,i)=>id('AB',i+1)).join(', ')}); runOnlyForDeploymentPostprocessing = 0; };`,
  `${frameworks} = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };`,
  `${resources} = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (${assetBuild}, ${privacyBuild}, ${careerSeedBuild}); runOnlyForDeploymentPostprocessing = 0; };`,
  `${testSources} = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (${testFiles.map((f,i)=>id('AE',i+1)).join(', ')}); runOnlyForDeploymentPostprocessing = 0; };`,
  `${testFrameworks} = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };`,
  `${testResources} = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };`,
  `${testProxy} = {isa = PBXContainerItemProxy; containerPortal = ${project}; proxyType = 1; remoteGlobalIDString = ${target}; remoteInfo = Daylight; };`,
  `${testDependency} = {isa = PBXTargetDependency; target = ${target}; targetProxy = ${testProxy}; };`,
  `${target} = {isa = PBXNativeTarget; buildConfigurationList = ${targetList}; buildPhases = (${sources}, ${frameworks}, ${resources}); buildRules = (); dependencies = (); name = Daylight; productName = Daylight; productReference = ${product}; productType = "com.apple.product-type.application"; };`,
  `${testTarget} = {isa = PBXNativeTarget; buildConfigurationList = ${testList}; buildPhases = (${testSources}, ${testFrameworks}, ${testResources}); buildRules = (); dependencies = (${testDependency}); name = DaylightUITests; productName = DaylightUITests; productReference = ${testProduct}; productType = "com.apple.product-type.bundle.ui-testing"; };`,
  `${project} = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1500; TargetAttributes = {${target} = {CreatedOnToolsVersion = 15.0; SystemCapabilities = {com.apple.HealthKit = {enabled = 1;};};}; ${testTarget} = {CreatedOnToolsVersion = 15.0; TestTargetID = ${target};};};}; buildConfigurationList = ${projList}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (en, "zh-Hans", Base); mainGroup = ${main}; productRefGroup = ${products}; projectDirPath = ""; projectRoot = ""; targets = (${target}, ${testTarget}); };`,
  `${debug} = {isa = XCBuildConfiguration; buildSettings = {CLANG_ENABLE_MODULES = YES; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf; GCC_PREPROCESSOR_DEFINITIONS = ("DEBUG=1", "$(inherited)"); SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;}; name = Debug; };`,
  `${release} = {isa = XCBuildConfiguration; buildSettings = {CLANG_ENABLE_MODULES = YES; SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; SWIFT_COMPILATION_MODE = wholemodule;}; name = Release; };`,
  `${targetDebug} = {isa = XCBuildConfiguration; buildSettings = {${completeNativeSettings}}; name = Debug; };`,
  `${targetRelease} = {isa = XCBuildConfiguration; buildSettings = {${completeNativeSettings}}; name = Release; };`,
  `${testDebug} = {isa = XCBuildConfiguration; buildSettings = {${testSettings}}; name = Debug; };`,
  `${testRelease} = {isa = XCBuildConfiguration; buildSettings = {${testSettings}}; name = Release; };`,
  `${projList} = {isa = XCConfigurationList; buildConfigurations = (${debug}, ${release}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };`,
  `${targetList} = {isa = XCConfigurationList; buildConfigurations = (${targetDebug}, ${targetRelease}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };`,
  `${testList} = {isa = XCConfigurationList; buildConfigurations = (${testDebug}, ${testRelease}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };`
];
const folder=path.join(base,'Daylight.xcodeproj');fs.mkdirSync(folder,{recursive:true});
fs.writeFileSync(path.join(folder,'project.pbxproj'),`// !$*UTF8*$!\n{\narchiveVersion = 1;\nclasses = {};\nobjectVersion = 56;\nobjects = {\n${objects.join('\n')}\n};\nrootObject = ${project};\n}\n`);
const schemes=path.join(folder,'xcshareddata','xcschemes');fs.mkdirSync(schemes,{recursive:true});
fs.writeFileSync(path.join(schemes,'Daylight.xcscheme'),`<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${target}" BuildableName="Daylight.app" BlueprintName="Daylight" ReferencedContainer="container:Daylight.xcodeproj"/></BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${testTarget}" BuildableName="DaylightUITests.xctest" BlueprintName="DaylightUITests" ReferencedContainer="container:Daylight.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES" codeCoverageEnabled="NO"><Testables><TestableReference skipped="NO" parallelizable="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${testTarget}" BuildableName="DaylightUITests.xctest" BlueprintName="DaylightUITests" ReferencedContainer="container:Daylight.xcodeproj"/></TestableReference></Testables><MacroExpansion><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${target}" BuildableName="Daylight.app" BlueprintName="Daylight" ReferencedContainer="container:Daylight.xcodeproj"/></MacroExpansion></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${target}" BuildableName="Daylight.app" BlueprintName="Daylight" ReferencedContainer="container:Daylight.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${target}" BuildableName="Daylight.app" BlueprintName="Daylight" ReferencedContainer="container:Daylight.xcodeproj"/></BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>`);
console.log(`已生成 Daylight.xcodeproj，包含 ${files.length} 个 App Swift 源文件和 ${testFiles.length} 个界面测试文件；尚未进行 Xcode 编译。`);
