#import <Orion/Orion.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>
#import "fishhook.h"
#import "Tweak.h"

#if THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#else
#import <libroot.h>
#endif

// MARK: - JBRoot / SB Utilities

NSString *EeveeJBRootPath(NSString *path) {
#if THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(path);
#else
    return JBROOT_PATH_NSSTRING(path);
#endif
}

void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument) {
    if (!target || !selector) return;
    typedef id (*SeekFn)(id, SEL, double);
    SeekFn fn = (SeekFn)objc_msgSend;
    (void)fn(target, selector, argument);
}

static void writeDebugLog(NSString *message) {
    NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"eeveespotify_debug.log"];
    NSString *timestamp = [[NSDate date] description];
    NSString *logMessage = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];

    if ([[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [logMessage writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// MARK: - Audio Stream Recorder (AudioUnit tap)

static os_unfair_lock g_audioLock = OS_UNFAIR_LOCK_INIT;
static AURenderCallback g_originalRenderCallback = NULL;
static void *g_originalRenderRefCon = NULL;
static AudioUnit g_activeAudioUnit = NULL;
static AudioStreamBasicDescription g_clientStreamFormat;
static BOOL g_hasClientStreamFormat = NO;

static ExtAudioFileRef g_extAudioFile = NULL;
static BOOL g_isRecording = NO;
static NSString *g_currentRecordingPath = nil;

static OSStatus EeveeAudioHookRenderCallback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
) {
    OSStatus status = noErr;
    if (g_originalRenderCallback) {
        status = g_originalRenderCallback(g_originalRenderRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    }
    
    if (status == noErr && ioData != NULL) {
        if (os_unfair_lock_trylock(&g_audioLock)) {
            if (g_isRecording && g_extAudioFile != NULL) {
                ExtAudioFileWriteAsync(g_extAudioFile, inNumberFrames, ioData);
            }
            os_unfair_lock_unlock(&g_audioLock);
        }
    }
    
    return status;
}

static OSStatus (*orig_AudioUnitSetProperty)(
    AudioUnit inUnit,
    AudioUnitPropertyID inID,
    AudioUnitScope inScope,
    AudioUnitElement inElement,
    const void *inData,
    UInt32 inDataSize
) = NULL;

static OSStatus hook_AudioUnitSetProperty(
    AudioUnit inUnit,
    AudioUnitPropertyID inID,
    AudioUnitScope inScope,
    AudioUnitElement inElement,
    const void *inData,
    UInt32 inDataSize
) {
    if (inID == kAudioUnitProperty_SetRenderCallback && inData != NULL) {
        const AURenderCallbackStruct *cb = (const AURenderCallbackStruct *)inData;
        g_originalRenderCallback = cb->inputProc;
        g_originalRenderRefCon = cb->inputProcRefCon;
        g_activeAudioUnit = inUnit;
        
        // Read client format
        AudioStreamBasicDescription asbd;
        UInt32 asbdSize = sizeof(asbd);
        if (AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inElement, &asbd, &asbdSize) == noErr) {
            g_clientStreamFormat = asbd;
            g_hasClientStreamFormat = YES;
        }

        AURenderCallbackStruct wrapped;
        wrapped.inputProc = EeveeAudioHookRenderCallback;
        wrapped.inputProcRefCon = (void *)inUnit;

        writeDebugLog(@"[AudioRecorder] Hooked AudioUnit render callback");
        return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, &wrapped, sizeof(wrapped));
    }
    
    if (inID == kAudioUnitProperty_StreamFormat && inData != NULL) {
        g_clientStreamFormat = *(const AudioStreamBasicDescription *)inData;
        g_hasClientStreamFormat = YES;
    }

    return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
}

void EeveeStartAudioRecording(NSString *outputPath) {
    if (g_isRecording) {
        EeveeStopAudioRecording();
    }
    
    if (!outputPath || outputPath.length == 0) return;
    
    NSString *parentDir = [outputPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
    
    AudioStreamBasicDescription clientFormat;
    if (g_hasClientStreamFormat) {
        clientFormat = g_clientStreamFormat;
    } else if (g_activeAudioUnit != NULL) {
        UInt32 size = sizeof(clientFormat);
        if (AudioUnitGetProperty(g_activeAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &clientFormat, &size) == noErr) {
            g_clientStreamFormat = clientFormat;
            g_hasClientStreamFormat = YES;
        } else {
            // Standard fallback
            clientFormat.mSampleRate = 44100.0;
            clientFormat.mFormatID = kAudioFormatLinearPCM;
            clientFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
            clientFormat.mBytesPerPacket = 8;
            clientFormat.mFramesPerPacket = 1;
            clientFormat.mBytesPerFrame = 8;
            clientFormat.mChannelsPerFrame = 2;
            clientFormat.mBitsPerChannel = 32;
        }
    } else {
        clientFormat.mSampleRate = 44100.0;
        clientFormat.mFormatID = kAudioFormatLinearPCM;
        clientFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        clientFormat.mBytesPerPacket = 8;
        clientFormat.mFramesPerPacket = 1;
        clientFormat.mBytesPerFrame = 8;
        clientFormat.mChannelsPerFrame = 2;
        clientFormat.mBitsPerChannel = 32;
    }

    // Output AAC format
    AudioStreamBasicDescription outDesc;
    memset(&outDesc, 0, sizeof(outDesc));
    outDesc.mFormatID = kAudioFormatMPEG4AAC;
    outDesc.mSampleRate = clientFormat.mSampleRate > 0 ? clientFormat.mSampleRate : 44100.0;
    outDesc.mChannelsPerFrame = clientFormat.mChannelsPerFrame > 0 ? clientFormat.mChannelsPerFrame : 2;

    NSURL *fileURL = [NSURL fileURLWithPath:outputPath];
    ExtAudioFileRef audioFile = NULL;
    OSStatus st = ExtAudioFileCreateWithURL((__bridge CFURLRef)fileURL, kAudioFileM4AType, &outDesc, NULL, kAudioFileFlags_EraseFile, &audioFile);
    
    if (st != noErr || audioFile == NULL) {
        writeDebugLog([NSString stringWithFormat:@"[AudioRecorder] ExtAudioFileCreateWithURL failed: %d", (int)st]);
        return;
    }

    // Set client data format (uncompressed PCM from render proc)
    st = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat, sizeof(clientFormat), &clientFormat);
    if (st != noErr) {
        writeDebugLog([NSString stringWithFormat:@"[AudioRecorder] Set ClientDataFormat failed: %d", (int)st]);
        ExtAudioFileDispose(audioFile);
        return;
    }

    os_unfair_lock_lock(&g_audioLock);
    g_extAudioFile = audioFile;
    g_currentRecordingPath = [outputPath copy];
    g_isRecording = YES;
    os_unfair_lock_unlock(&g_audioLock);

    writeDebugLog([NSString stringWithFormat:@"[AudioRecorder] Started recording to %@", outputPath]);
}

void EeveeStopAudioRecording(void) {
    os_unfair_lock_lock(&g_audioLock);
    if (!g_isRecording && g_extAudioFile == NULL) {
        os_unfair_lock_unlock(&g_audioLock);
        return;
    }
    
    g_isRecording = NO;
    ExtAudioFileRef fileToDispose = g_extAudioFile;
    g_extAudioFile = NULL;
    NSString *closedPath = g_currentRecordingPath;
    g_currentRecordingPath = nil;
    os_unfair_lock_unlock(&g_audioLock);

    if (fileToDispose != NULL) {
        ExtAudioFileDispose(fileToDispose);
        writeDebugLog([NSString stringWithFormat:@"[AudioRecorder] Stopped recording. Finalized %@", closedPath]);
    }
}

BOOL EeveeIsAudioRecording(void) {
    os_unfair_lock_lock(&g_audioLock);
    BOOL recording = g_isRecording;
    os_unfair_lock_unlock(&g_audioLock);
    return recording;
}

// MARK: - Constructor

__attribute__((constructor)) static void init() {
    @try {
        NSLog(@"[EeveeSpotify] Initializing tweak...");

        // Hook AudioUnitSetProperty using fishhook
        struct rebinding rebindings[] = {
            {"AudioUnitSetProperty", hook_AudioUnitSetProperty, (void *)&orig_AudioUnitSetProperty}
        };
        rebind_symbols(rebindings, 1);

        // Initialize Orion - do not remove this line.
        orion_init();

        NSLog(@"[EeveeSpotify] Tweak initialized successfully");
    }
    @catch (NSException *exception) {
        NSString *errorMsg = [NSString stringWithFormat:@"ERROR: Failed to initialize tweak: %@, Reason: %@", exception, [exception reason]];
        NSLog(@"[EeveeSpotify] %@", errorMsg);
        writeDebugLog(errorMsg);
    }
}
