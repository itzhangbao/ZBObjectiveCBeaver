//
//  ZBServerDestination.m
//  ZBObjectiveCBeaver
//
//  Created by Jumbo on 2021/3/17.
//

#import <UIKit/UIKit.h>
#import "ZBServerDestination.h"
#import <sys/utsname.h>

#if __has_include(<ZBObjectiveCBeaver/ZBAVOSCloudDestination.h>)
#import <ZBObjectiveCBeaver/ZBAVOSCloudDestination.h>
#endif

@interface ZBServerDestination()

@property (nonatomic, assign) NSInteger points;

// over-rules SendingPoints.Threshold
@property (nonatomic, assign) NSInteger minAllowedThreshold;

// over-rules SendingPoints.Threshold
@property (nonatomic, assign) NSInteger maxAllowedThreshold;

@property (nonatomic, assign) BOOL sendingInProgress;

@property (nonatomic, assign) BOOL initialSending;

// analytics
@property (nonatomic, strong) NSString *uuid;

@property (nonatomic, weak) NSFileManager *fileManager;

@property (nonatomic, strong) NSDateFormatter *isoDateFormatter;

@end

@implementation ZBServerDestination

- (NSString *)analyticsUUID {
    return self.uuid;
}

- (instancetype)initWithAppID:(NSString *)appID
                    appSecret:(NSString *)appSecret
                encryptionKey:(NSString *)encryptionKey
                    serverURL:(NSString *)serverURL
              entriesFileName:(NSString *)entriesFileName
              sendingfileName:(NSString *)sendingfileName
            analyticsFileName:(NSString *)analyticsFileName
                   serverType:(ZBServerType)serverType {
    self = [super init];
    if (self) {
        
        _showNSLog = NO;
        
        _entriesFileURL = [NSURL fileURLWithPath:@""];
        _sendingFileURL = [NSURL fileURLWithPath:@""];
        _analyticsFileURL = [NSURL fileURLWithPath:@""];
        
        _minAllowedThreshold = 1;
        _maxAllowedThreshold = 1000;
        _sendingInProgress = NO;
        _initialSending = YES;
        
        _serverType = serverType;
        
        _uuid = @"";
        
        _fileManager = [NSFileManager defaultManager];
        _isoDateFormatter = [[NSDateFormatter alloc] init];
        
        _serverURL = serverURL;
        _appID = appID;
        _appSecret = appSecret;
        _encryptionKey = encryptionKey;
        
        NSURL *baseURL = [_fileManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        
        if (baseURL) {
            
            NSString *_entriesFileName =
            entriesFileName.length > 0 ? entriesFileName : @"zbserver_entries.json";
            
            NSString *_sendingfileName =
            sendingfileName.length > 0 ? sendingfileName : @"zbserver_entries_sending.json";
            
            NSString *_analyticsFileName =
            analyticsFileName.length > 0 ? analyticsFileName : @"zbserver_analytics.json";
            
            _entriesFileURL = [baseURL URLByAppendingPathComponent:_entriesFileName isDirectory:NO];
            _sendingFileURL = [baseURL URLByAppendingPathComponent:_sendingfileName isDirectory:NO];
            _analyticsFileURL = [baseURL URLByAppendingPathComponent:_analyticsFileName isDirectory:NO];
            
            // get, update loaded and save analytics data to file on start
            NSDictionary *dict = [self analytics:YES];
            [self saveDictToFile:dict url:_analyticsFileURL];
        }
    }
    return self;
}

// append to file, each line is a JSON dict
- (NSString *)send:(ZBLogLevel)level msg:(NSString *)msg thread:(NSString *)thread file:(NSString *)file function:(NSString *)function line:(NSUInteger)line context:(id)context {
    
    NSString *jsonString = nil;
    
    NSDictionary *dict = @{@"timestamp": @([NSDate new].timeIntervalSince1970),
                           @"level"    : @(level),
                           @"message"  : msg,
                           @"thread"   : thread,
                           @"fileName" : [file componentsSeparatedByString:@"/"].lastObject,
                           @"function" : function,
                           @"line"     : @(line)
    };
    
    jsonString = [self jsonStringFromDict:dict];
    
    if (jsonString) {
        [self toNSLog:[NSString stringWithFormat:@"saving %@ to %@", msg, _entriesFileURL]];
        
        [self saveToFile:jsonString url:_entriesFileURL overwrite:NO];
        
        // now decide if the stored log entries should be sent to the server
        // add level points to current points amount and send to server if threshold is hit
        _points += [self sendingPointsForLevel:level];
        
        if ((_points >= ZBSendingPointsThreshold && _points >= _minAllowedThreshold) || _points > _maxAllowedThreshold) {
            [self toNSLog:[NSString stringWithFormat:@"%ld points is >= threshold", (long)_points]];
            // above threshold, send to server
            [self sendNow];
            
        }else if (_initialSending) {
            _initialSending = NO;
            // first logging at this session
            // send if json file still contains old log entries
            NSArray *logEntries = [self logsFromFile:_entriesFileURL];
            if (logEntries) {
                NSInteger lines = logEntries.count;
                if (lines > 1) {
                    [self toNSLog:[NSString stringWithFormat:@"initialSending: %ld points is below threshold but json file already has %ld lines.", (long)_points, (long)lines]];
                    [self sendNow];
                }
            }
        }
    }
    
    return jsonString;
}

// MARK: Send-to-Server Logic

/// does a (manual) sending attempt of all unsent log entries to zb server
- (void)sendNow {
    if ([self sendFileExists]) {
        [self toNSLog:@"reset points to 0"];
        _points = 0;
    }else {
        if (![self renameJsonToSendFile]) {
            return;
        }
    }
    
    if (!_sendingInProgress) {
        _sendingInProgress = YES;
        NSInteger lines = 0;
        
        NSArray *logEntries = [self logsFromFile:_sendingFileURL];
        if (!logEntries) {
            _sendingInProgress = NO;
            return;
        }
        
        lines = logEntries.count;
        
        if (lines > 0) {
            // merge device and analytics dictionaries
            NSMutableDictionary *deviceDetailsDict = [self deviceDetails];
            
            NSMutableDictionary *analyticsDict = [self analytics:NO];
            
            for (id key in deviceDetailsDict.allKeys) {
                analyticsDict[key] = deviceDetailsDict[key];
            }
            
            _sendingInProgress = YES;
            
            __weak typeof(self) _self = self;
            void (^complete)(BOOL) = ^(BOOL ok) {
                if (ok) {
                    [_self deleteFile:_self.sendingFileURL];
                }
                _self.sendingInProgress = NO;
                _self.points = 0;
            };
            
            if (_serverType == ZBServerTypeAVOSCloud) {
                [self sendToAvosCloudWithDevice:analyticsDict logs:logEntries complete:complete];
            }else {
                [self sendToCustmAPIWithDevice:analyticsDict logs:logEntries complete:complete];
            }
            
        }else {
            _sendingInProgress = NO;
        }
    }
}

// Send information to custom AVOSCLOUD (https://leancloud.cn/)
- (void)sendToAvosCloudWithDevice:(NSDictionary *)deviceDic logs:(NSArray *)logs complete:(void(^)(BOOL ok))complete {
    
}

// Send information to custom server
- (void)sendToCustmAPIWithDevice:(NSDictionary *)deviceDic logs:(NSArray *)logs complete:(void(^)(BOOL ok))complete {
    
}

// MARK: Device & Analytics

// returns dict with device details. Amount depends on platform
- (NSMutableDictionary *)deviceDetails {
    NSMutableDictionary *details = [NSMutableDictionary new];
    
//    details[@"os"] = @"";
    NSOperatingSystemVersion osVersion = NSProcessInfo.processInfo.operatingSystemVersion;
    NSString *osVersionStr = [NSString stringWithFormat:@"%ld.%ld.%ld", (long)osVersion.majorVersion, (long)osVersion.minorVersion, (long)osVersion.patchVersion];
    details[@"osVersion"] = osVersionStr;
    details[@"deviceName"] = UIDevice.currentDevice.name;
    details[@"deviceModel"] = [self deviceModel];
    details[@"hostName"] = @"";
    
    return details;
}

- (NSString *)deviceModel {
    struct utsname systemInfo;
    uname(&systemInfo);
    return [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
}

// returns (updated) analytics dict, optionally loaded from file.
- (NSMutableDictionary *)analytics:(BOOL)update {
    NSMutableDictionary *dict = [NSMutableDictionary new];
    double now = [NSDate new].timeIntervalSince1970;
    
    _uuid = NSUUID.UUID.UUIDString;
    dict[@"uuid"] = _uuid;
    dict[@"firstStart"] = @(now);
    dict[@"lastStart"] = @(now);
    dict[@"starts"] = @(1);
    dict[@"userName"] = _analyticsUserName;
    dict[@"firstAppVersion"] = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    dict[@"appVersion"] = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    dict[@"firstAppBuild"] = [[NSBundle mainBundle] infoDictionary][@"CFBundleVersion"];
    dict[@"appBuild"] = [[NSBundle mainBundle] infoDictionary][@"CFBundleVersion"];
    
    NSMutableDictionary *loadedDict = [self dictFromFile:_analyticsFileURL];
    if (loadedDict) {
        id val = loadedDict[@"firstStart"];
        if (val) {
            dict[@"firstStart"] = val;
        }
        val = loadedDict[@"lastStart"];
        if (val) {
            if (update) {
                dict[@"lastStart"] = @(now);
            }else {
                dict[@"lastStart"] = val;
            }
        }
        val = loadedDict[@"starts"];
        if (val) {
            if (update) {
                dict[@"starts"] = @([val integerValue] + 1);
            }else {
                dict[@"starts"] = val;
            }
        }
        val = loadedDict[@"uuid"];
        if (val) {
            dict[@"uuid"] = val;
            _uuid = val;
        }
        val = loadedDict[@"userName"];
        if (update && _analyticsUserName) {
            dict[@"userName"] = _analyticsUserName;
        }else {
            if (val) {
                dict[@"userName"] = val;
            }
        }
        val = loadedDict[@"firstAppVersion"];
        if (val) {
            dict[@"firstAppVersion"] = val;
        }
        val = loadedDict[@"firstAppBuild"];
        if (val) {
            dict[@"firstAppBuild"] = val;
        }
    }
    
    return dict;
}

// returns optional dict from a json encoded file
- (NSMutableDictionary *)dictFromFile:(NSURL *)url {
    NSError *error = nil;
    NSString *fileContent = [NSString stringWithContentsOfFile:url.path encoding:NSUTF8StringEncoding error:&error];
    if (error) {
        [self toNSLog:[NSString stringWithFormat:@"ZBServer Destination could not read file %@", url]];
        return nil;
    }
    NSData *data = [fileContent dataUsingEncoding:NSUTF8StringEncoding];
    if (data) {
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
        if (error) {
            [self toNSLog:[NSString stringWithFormat:@"ZBServer Destination could not read file %@", url]];
            return nil;
        }
        return [NSMutableDictionary dictionaryWithDictionary:dict];
    }
    return nil;
}

// turns dict into JSON-encoded string
- (NSString *)jsonStringFromDict:(NSDictionary *)dict {
    
    NSError *error;

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&error];

    NSString *jsonString;

    if (!jsonData) {
        
        [self toNSLog:[NSString stringWithFormat:@"ZBServer: json data error %@", error]];
        
    }else{
        
        jsonString = [[NSString alloc]initWithData:jsonData encoding:NSUTF8StringEncoding];
    }

    NSMutableString *mutStr = [NSMutableString stringWithString:jsonString];

    NSRange range = {0,jsonString.length};

    //remove spaces from strings
    [mutStr replaceOccurrencesOfString:@" " withString:@"" options:NSLiteralSearch range:range];
    NSRange range2 = {0,mutStr.length};

    //remove the newline character from the string
    [mutStr replaceOccurrencesOfString:@"\n" withString:@"" options:NSLiteralSearch range:range2];

    return mutStr;
}

/// returns sending points based on level
- (NSInteger)sendingPointsForLevel:(ZBLogLevel)level {
    switch (level) {
        case ZBLogLevelDebug:   return ZBSendingPointsDebug;
        case ZBLogLevelInfo:    return ZBSendingPointsInfo;
        case ZBLogLevelWarning: return ZBSendingPointsWarning;
        case ZBLogLevelError:   return ZBSendingPointsError;
        default:                return ZBSendingPointsVerbose;
    }
}

// MARK: File Handling

/// appends a string as line to a file.
/// returns boolean about success
- (BOOL)saveToFile:(NSString *)str url:(NSURL *)url overwrite:(BOOL)overwrite {
    
    NSError *error = nil;
    NSString *line = [str stringByAppendingString:@"\n"];
    
    if (![_fileManager fileExistsAtPath:url.path] || overwrite) {
        // create file if not existing
        [line writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error];
    }else {
        // append to end of file
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingToURL:url error:&error];
        [fileHandle seekToEndOfFile];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (data) {
            [fileHandle writeData:data];
            [fileHandle closeFile];
        }
    }
    
    if (error) {
        [self toNSLog:[NSString stringWithFormat:@"Error! Could not write to file %@", url]];
        return NO;
    }
    return YES;
}

// turns dict into JSON and saves it to file
- (BOOL)saveDictToFile:(NSDictionary *)dict url:(NSURL *)url {
    NSString *jsonString = [self jsonStringFromDict:dict];
    
    if (jsonString && ![jsonString isEqualToString:@""]) {
        [self toNSLog:[NSString stringWithFormat:@"saving %@ to %@", jsonString, url]];
        return [self saveToFile:jsonString url:url overwrite:YES];
    }
    
    return NO;
}

- (BOOL)sendFileExists {
    return [_fileManager fileExistsAtPath:_sendingFileURL.path];
}

- (BOOL)renameJsonToSendFile {
    NSError *error = nil;
    [_fileManager moveItemAtURL:_entriesFileURL toURL:_sendingFileURL error:&error];
    if (error) {
        [self toNSLog:@"ZBServer Destination could not rename json file."];
        return NO;
    }
    return YES;
}

/// returns optional array of log dicts from a file which has 1 json string per line
- (NSArray *)logsFromFile:(NSURL *)url {
    NSInteger lines = 0;
    // try to read file, decode every JSON line and put dict from each line in array
    NSError *error = nil;
    NSString *fileContent = [NSString stringWithContentsOfFile:url.path encoding:NSUTF8StringEncoding error:&error];
    if (error) {
        [self toNSLog:[NSString stringWithFormat:@"Error! Could not read file %@.", url]];
        return nil;
    }
    NSArray *linesArray = [fileContent componentsSeparatedByString:@"\n"]; // array of dictionaries
    NSMutableArray *dicts = [NSMutableArray new];
    for (NSString *lineJSON in linesArray) {
        lines += 1;
        if (lineJSON.length > 0 && [[lineJSON substringToIndex:1] isEqualToString:@"{"] &&
            [[lineJSON substringFromIndex:lineJSON.length - 1] isEqualToString:@"}"]) {
            // try to parse json string into dict
            NSData *data = [lineJSON dataUsingEncoding:NSUTF8StringEncoding];
            if (data) {
                NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
                if (error) {
                    [self toNSLog:[NSString stringWithFormat:@"Error! Could not parse line %ld in file %@.",(long)lines, url]];
                    return nil;
                }
                if (dict) {
                    [dicts addObject:dict];
                }
            }
        }
    }
    [dicts removeObjectAtIndex:0];
    return dicts;
}

// MARK: Debug Helpers

/// log String to toNSLog. Used to debug the class logic
- (void)toNSLog:(NSString *)str {
    if (_showNSLog) {
        NSLog(@"ZBServer: %@", str);
    }
}

/// Delete file to get started again
- (BOOL)deleteFile:(NSURL *)url {
    NSError *error = nil;
    [_fileManager removeItemAtURL:url error:&error];
    if (error) {
        [self toNSLog:[NSString stringWithFormat:@"Warning! Could not delete firl %@.", url]];
        return NO;
    }
    return YES;
}

@end
