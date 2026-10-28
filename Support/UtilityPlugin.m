#import <Foundation/Foundation.h>

const char *dial_plugin_run(const char *requestJSON) {
    @autoreleasepool {
        static NSString *response;
        NSData *input = [[NSString stringWithUTF8String:requestJSON] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
        NSString *action = request[@"action"];
        NSDictionary *settings = request[@"settings"];
        NSString *key = [action isEqualToString:@"open-url"] ? @"url" : ([action isEqualToString:@"open-app"] ? @"application" : @"path");
        NSString *outputKey = [action isEqualToString:@"open-url"] ? @"openURL" : ([action isEqualToString:@"open-app"] ? @"openApplication" : @"openPath");
        id value = settings[key];
        NSDictionary *result = [value isKindOfClass:NSString.class] && [value length] > 0 ? @{outputKey: value} : @{@"error": @"The action setting is empty"};
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        response = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
        return response.UTF8String;
    }
}
