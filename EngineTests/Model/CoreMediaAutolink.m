// The model/edit/scheduler tests call CoreMedia (CMTime) directly, but project.yml does not
// list CoreMedia for the EngineTests target. Xcode enables clang modules for C/Objective-C
// (not C++/Objective-C++), so importing the module here makes the linker autolink
// CoreMedia.framework into the test bundle. Harmless if the framework is also linked explicitly.

@import CoreMedia;
