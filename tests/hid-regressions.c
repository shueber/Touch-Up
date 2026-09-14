#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  IOHIDElementRef element;
  IOHIDElementRef parent;
  CFMutableArrayRef children;
  CFDictionaryRef properties;
} FixtureNode;

static FixtureNode fixture_nodes[256];
static size_t fixture_node_count;
static CFMutableArrayRef fixture_queue_values;
static CFIndex fixture_queue_index;

static IOHIDElementRef FixtureGetParent(IOHIDElementRef element) {
  for (size_t i = 0; i < fixture_node_count; i++) {
    if (fixture_nodes[i].element == element) return fixture_nodes[i].parent;
  }
  return IOHIDElementGetParent(element);
}

static CFArrayRef FixtureGetChildren(IOHIDElementRef element) {
  for (size_t i = 0; i < fixture_node_count; i++) {
    if (fixture_nodes[i].element == element) return fixture_nodes[i].children;
  }
  return IOHIDElementGetChildren(element);
}

static CFIndex FixtureProperty(IOHIDElementRef element, CFStringRef key) {
  for (size_t i = 0; i < fixture_node_count; i++) {
    if (fixture_nodes[i].element != element) continue;
    CFNumberRef value = CFDictionaryGetValue(fixture_nodes[i].properties, key);
    CFIndex result = 0;
    if (value) CFNumberGetValue(value, kCFNumberCFIndexType, &result);
    return result;
  }
  abort();
}

static IOHIDElementRef FixtureValueElement(IOHIDValueRef value) {
  return (IOHIDElementRef)CFArrayGetValueAtIndex((CFArrayRef)value, 0);
}

static CFIndex FixtureValueInteger(IOHIDValueRef value) {
  CFIndex integer;
  CFNumberGetValue(CFArrayGetValueAtIndex((CFArrayRef)value, 1),
    kCFNumberCFIndexType, &integer);
  return integer;
}

static uint64_t FixtureValueTimestamp(IOHIDValueRef value) {
  uint64_t timestamp;
  CFNumberGetValue(CFArrayGetValueAtIndex((CFArrayRef)value, 2),
    kCFNumberSInt64Type, &timestamp);
  return timestamp;
}

static IOHIDValueRef FixtureCopyNextValue(IOHIDQueueRef queue, CFTimeInterval timeout) {
  if (fixture_queue_index == CFArrayGetCount(fixture_queue_values)) return NULL;
  return (IOHIDValueRef)CFRetain(CFArrayGetValueAtIndex(fixture_queue_values,
    fixture_queue_index++));
}

#define IOHIDElementGetParent FixtureGetParent
#define IOHIDElementGetChildren FixtureGetChildren
#define IOHIDElementGetType(e) FixtureProperty(e, CFSTR("Type"))
#define IOHIDElementGetCollectionType(e) FixtureProperty(e, CFSTR("CollectionType"))
#define IOHIDElementGetUsagePage(e) FixtureProperty(e, CFSTR("UsagePage"))
#define IOHIDElementGetUsage(e) FixtureProperty(e, CFSTR("Usage"))
#define IOHIDElementGetCookie(e) FixtureProperty(e, CFSTR("ElementCookie"))
#define IOHIDElementGetLogicalMin(e) FixtureProperty(e, CFSTR("Min"))
#define IOHIDElementGetLogicalMax(e) FixtureProperty(e, CFSTR("Max"))
#define IOHIDElementGetReportID(e) FixtureProperty(e, CFSTR("ReportID"))
#define IOHIDValueGetElement FixtureValueElement
#define IOHIDValueGetIntegerValue FixtureValueInteger
#define IOHIDValueGetTimeStamp FixtureValueTimestamp
#define IOHIDQueueCopyNextValueWithTimeout FixtureCopyNextValue
#include "../TouchUpCore/HIDInterpreter.c"

static int failures;
static int touch_updates;
static int report_updates;
static CFIndex last_contact_id;
static CGPoint last_position;
static Boolean last_on_surface;
static CFIndex contact_history[64];
static CGPoint position_history[64];

static void Check(Boolean condition, const char *message) {
  printf("%s %s\n", condition ? "PASS" : "FAIL", message);
  if (!condition) failures++;
}

void TouchInputManagerUpdateTouchPosition(void *self, uint32_t location_id,
  CFIndex contact_id, CGFloat x, CGFloat y, Boolean on_surface, Boolean is_valid) {
  touch_updates++;
  if (touch_updates <= 64) {
    contact_history[touch_updates - 1] = contact_id;
    position_history[touch_updates - 1] = CGPointMake(x, y);
  }
  last_contact_id = contact_id;
  last_position = CGPointMake(x, y);
  last_on_surface = on_surface;
}

void TouchInputManagerUpdateTouchSize(void *self, uint32_t location_id,
  CFIndex contact_id, CGFloat width, CGFloat height, CGFloat azimuth) {}

void TouchInputManagerDidProcessReport(void *self, uint32_t location_id) {
  report_updates++;
}

void TouchInputManagerDidConnectTouchscreen(void *self, uint32_t location_id) {}
void TouchInputManagerDidDisconnectTouchscreen(void *self, uint32_t location_id) {}

static IOHIDElementRef CreateFixtureNode(CFDictionaryRef properties,
  IOHIDElementRef parent) {
  if (fixture_node_count >= sizeof(fixture_nodes) / sizeof(fixture_nodes[0])) abort();
  FixtureNode *node = &fixture_nodes[fixture_node_count++];
  node->element = IOHIDElementCreateWithDictionary(NULL, properties);
  if (!node->element) abort();
  node->properties = CFRetain(properties);
  node->parent = parent;
  node->children = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
  CFArrayRef children = CFDictionaryGetValue(properties, CFSTR("Elements"));
  for (CFIndex i = 0; children && i < CFArrayGetCount(children); i++) {
    IOHIDElementRef child = CreateFixtureNode(CFArrayGetValueAtIndex(children, i),
      node->element);
    CFArrayAppendValue(node->children, child);
  }
  return node->element;
}

static IOHIDElementRef LoadFixture(const char *directory, const char *report) {
  char path[4096];
  snprintf(path, sizeof(path), "%s/m14t-report-%s-elements.plist", directory, report);
  FILE *file = fopen(path, "rb");
  if (!file) { perror(path); exit(2); }
  fseek(file, 0, SEEK_END);
  long length = ftell(file);
  rewind(file);
  UInt8 *bytes = malloc((size_t)length);
  if (!bytes || fread(bytes, 1, (size_t)length, file) != (size_t)length) abort();
  fclose(file);
  CFDataRef data = CFDataCreate(NULL, bytes, length);
  free(bytes);
  CFPropertyListRef properties = CFPropertyListCreateWithData(NULL, data,
    kCFPropertyListImmutable, NULL, NULL);
  if (!properties) abort();
  IOHIDElementRef root = CreateFixtureNode(properties, NULL);
  CFRelease(properties);
  CFRelease(data);
  return root;
}

static IOHIDElementRef FindElement(IOHIDElementRef root, uint32_t page,
  uint32_t usage) {
  if (IOHIDElementGetUsagePage(root) == page && IOHIDElementGetUsage(root) == usage) {
    return root;
  }
  CFArrayRef children = FixtureGetChildren(root);
  for (CFIndex i = 0; children && i < CFArrayGetCount(children); i++) {
    IOHIDElementRef found = FindElement((IOHIDElementRef)CFArrayGetValueAtIndex(children, i),
      page, usage);
    if (found) return found;
  }
  return NULL;
}

static void StoreValue(HIDDeviceState *device, IOHIDElementRef element, CFIndex value) {
  CFNumberRef number = CFNumberCreate(NULL, kCFNumberCFIndexType, &value);
  const void *fields[] = {element, number};
  CFArrayRef input = CFArrayCreate(NULL, fields, 2, &kCFTypeArrayCallBacks);
  StoreInputValue(device, (IOHIDValueRef)input);
  CFRelease(input);
  CFRelease(number);
}

static void QueueValue(IOHIDElementRef element, CFIndex value, uint64_t timestamp) {
  CFNumberRef number = CFNumberCreate(NULL, kCFNumberCFIndexType, &value);
  CFNumberRef time = CFNumberCreate(NULL, kCFNumberSInt64Type, &timestamp);
  const void *fields[] = {element, number, time};
  CFArrayRef input = CFArrayCreate(NULL, fields, 3, &kCFTypeArrayCallBacks);
  CFArrayAppendValue(fixture_queue_values, input);
  CFRelease(input);
  CFRelease(number);
  CFRelease(time);
}

static void QueueContact(IOHIDElementRef finger, CFIndex contact_id, CFIndex x,
  CFIndex y, uint64_t timestamp) {
  QueueValue(FindElement(finger, kHIDPage_Digitizer, kHIDUsage_Dig_TipSwitch), 1, timestamp);
  QueueValue(FindElement(finger, kHIDPage_Digitizer, kHIDUsage_Dig_ContactIdentifier),
    contact_id, timestamp);
  QueueValue(FindElement(finger, kHIDPage_GenericDesktop, kHIDUsage_GD_X), x, timestamp);
  QueueValue(FindElement(finger, kHIDPage_GenericDesktop, kHIDUsage_GD_Y), y, timestamp);
}

static void TestBatchedQueueReports(IOHIDElementRef root) {
  HIDDeviceState *device = AllocateDeviceState((IOHIDDeviceRef)root, 1);
  IdentifyElements(device, root, FALSE);
  fixture_queue_values = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
  fixture_queue_index = 0;
  IOHIDElementRef count = FindElement(root, kHIDPage_Digitizer, kHIDUsage_Dig_ContactCount);
  IOHIDElementRef finger = (IOHIDElementRef)CFArrayGetValueAtIndex(device->touchCollectionElements, 0);
  QueueValue(count, 1, 100);
  QueueContact(finger, 1, 1237, 1392, 100);
  QueueValue(count, 1, 200);
  QueueContact(finger, 1, 2474, 2784, 200);
  touch_updates = 0;
  report_updates = 0;
  Handle_QueueValueAvailable((void *)root, kIOReturnSuccess, (void *)fixture_queue_values);
  Check(touch_updates == 2 && report_updates == 2 &&
    fabs(position_history[0].x - 0.1) < 0.001 &&
    fabs(position_history[1].x - 0.2) < 0.001,
    "one queue notification preserves both timestamped touch frames");
  Handle_QueueValueAvailable((void *)root, kIOReturnSuccess, (void *)fixture_queue_values);
  Check(touch_updates == 2 && report_updates == 2,
    "an empty queue notification does not emit a stale touch frame");
  CFRelease(fixture_queue_values);
  DeallocateDeviceState((IOHIDDeviceRef)root);
}

static void TestHybridQueueReports(IOHIDElementRef root) {
  HIDDeviceState *device = AllocateDeviceState((IOHIDDeviceRef)root, 1);
  IdentifyElements(device, root, FALSE);
  fixture_queue_values = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
  fixture_queue_index = 0;
  IOHIDElementRef count = FindElement(root, kHIDPage_Digitizer, kHIDUsage_Dig_ContactCount);
  QueueValue(count, 6, 100);
  for (CFIndex i = 0; i < 5; i++) {
    IOHIDElementRef finger = (IOHIDElementRef)CFArrayGetValueAtIndex(device->touchCollectionElements, i);
    QueueContact(finger, i + 1, 1000 * (i + 1), 500 * (i + 1), 100);
  }
  QueueValue(count, 0, 200);
  IOHIDElementRef first = (IOHIDElementRef)CFArrayGetValueAtIndex(device->touchCollectionElements, 0);
  QueueContact(first, 6, 6000, 3000, 200);
  touch_updates = 0;
  report_updates = 0;
  Handle_QueueValueAvailable((void *)root, kIOReturnSuccess, (void *)fixture_queue_values);
  Boolean all_contacts_preserved = touch_updates == 6;
  for (CFIndex i = 0; i < 6 && all_contacts_preserved; i++) {
    all_contacts_preserved = contact_history[i] == i + 1 &&
      fabs(position_history[i].x - (CGFloat)(1000 * (i + 1)) / 12372.0) < 0.00001;
  }
  Check(all_contacts_preserved && report_updates == 1 && device->hybridOffset == 0,
    "a batched 5+1 hybrid report preserves six contacts and completes one frame");
  CFRelease(fixture_queue_values);
  DeallocateDeviceState((IOHIDDeviceRef)root);
}

static void TestUnrelatedApplications(IOHIDElementRef root) {
  HIDDeviceState *device = AllocateDeviceState((IOHIDDeviceRef)root, 1);
  IdentifyElements(device, root, FALSE);
  IOHIDElementRef tip = FindElement(root, kHIDPage_Digitizer, kHIDUsage_Dig_TipSwitch);
  IdentifyElements(device, tip, FALSE);
  Check(CFArrayGetCount(device->touchCollectionElements) == 5 && device->areElementRefsSet,
    "repeated collection discovery does not duplicate contacts");
  CFDictionaryRef properties = NULL;
  for (size_t i = 0; i < fixture_node_count; i++) {
    if (fixture_nodes[i].element == root) properties = fixture_nodes[i].properties;
  }
  // Keep the same nested finger-like usages under unrelated application roots;
  // ancestry, rather than a coincidentally matching leaf usage, must decide.
  uint32_t pages[] = {kHIDPage_Digitizer, 0xff11};
  uint32_t usages[] = {kHIDUsage_Dig_Pen, 0x11};
  for (size_t i = 0; i < 2; i++) {
    CFMutableDictionaryRef unrelated = CFDictionaryCreateMutableCopy(NULL, 0, properties);
    CFNumberRef page = CFNumberCreate(NULL, kCFNumberSInt32Type, &pages[i]);
    CFNumberRef usage = CFNumberCreate(NULL, kCFNumberSInt32Type, &usages[i]);
    CFDictionarySetValue(unrelated, CFSTR("UsagePage"), page);
    CFDictionarySetValue(unrelated, CFSTR("Usage"), usage);
    IOHIDElementRef application = CreateFixtureNode(unrelated, NULL);
    IOHIDElementRef other_tip = FindElement(application, kHIDPage_Digitizer, kHIDUsage_Dig_TipSwitch);
    IdentifyElements(device, other_tip, FALSE);
    Check(TouchscreenCollectionForElement(other_tip) == NULL &&
      device->applicationCollectionElement == root &&
      CFArrayGetCount(device->touchCollectionElements) == 5,
      i == 0 ? "pen application cannot replace touchscreen discovery" :
        "vendor application cannot replace touchscreen discovery");
    CFRelease(usage);
    CFRelease(page);
    CFRelease(unrelated);
  }
  DeallocateDeviceState((IOHIDDeviceRef)root);
}

static void TestCollectionDiscovery(IOHIDElementRef root, CFIndex expected_count,
  const char *report) {
  IOHIDElementRef tip = FindElement(root, kHIDPage_Digitizer, kHIDUsage_Dig_TipSwitch);
  IOHIDElementRef count = FindElement(root, kHIDPage_Digitizer, kHIDUsage_Dig_ContactCount);
  IOHIDElementRef starts[] = {tip, count, root};
  const char *start_names[] = {"finger value", "contact count", "application root"};
  for (size_t i = 0; i < 3; i++) {
    HIDDeviceState *device = AllocateDeviceState((IOHIDDeviceRef)root, 1);
    IdentifyElements(device, starts[i], FALSE);
    char message[256];
    snprintf(message, sizeof(message), "M14t report %s discovers %ld contacts from %s",
      report, expected_count, start_names[i]);
    Check(CFArrayGetCount(device->touchCollectionElements) == expected_count, message);
    DeallocateDeviceState((IOHIDDeviceRef)root);
  }
}

static void TestStoredValues(IOHIDElementRef root) {
  HIDDeviceState *device = AllocateDeviceState((IOHIDDeviceRef)root, 1);
  IOHIDElementRef x = FindElement(root, kHIDPage_GenericDesktop, kHIDUsage_GD_X);
  IOHIDElementRef y = FindElement(root, kHIDPage_GenericDesktop, kHIDUsage_GD_Y);
  StoreValue(device, x, 1234);
  StoreValue(device, y, 5678);
  // Retain a separately-created equal key: a correct dictionary owns its key and
  // uses numeric equality, so lookup remains valid independently of allocations.
  uint32_t cookie = IOHIDElementGetCookie(x);
  CFNumberRef equal_key = CFNumberCreate(NULL, kCFNumberSInt32Type, &cookie);
  Check(CFDictionaryContainsKey(device->storedInputValues, equal_key),
    "stored values can be looked up using an independently allocated equal cookie");
  CFRelease(equal_key);
  Check(ValueOfElement(device, x) == 1234, "X value survives storing Y");
  Check(ValueOfElement(device, y) == 5678, "Y value survives releasing input objects");
  DeallocateDeviceState((IOHIDDeviceRef)root);
}

static void TestTouchDispatch(IOHIDElementRef root) {
  HIDDeviceState *device = AllocateDeviceState((IOHIDDeviceRef)root, 1);
  IOHIDElementRef count = FindElement(root, kHIDPage_Digitizer, kHIDUsage_Dig_ContactCount);
  IOHIDElementRef tip = FindElement(root, kHIDPage_Digitizer, kHIDUsage_Dig_TipSwitch);
  IOHIDElementRef id = FindElement(root, kHIDPage_Digitizer, kHIDUsage_Dig_ContactIdentifier);
  IOHIDElementRef x = FindElement(root, kHIDPage_GenericDesktop, kHIDUsage_GD_X);
  IOHIDElementRef y = FindElement(root, kHIDPage_GenericDesktop, kHIDUsage_GD_Y);
  IdentifyElements(device, count, FALSE);
  StoreValue(device, count, 1);
  StoreValue(device, tip, 1);
  StoreValue(device, id, 123);
  StoreValue(device, x, IOHIDElementGetLogicalMax(x) / 2);
  StoreValue(device, y, IOHIDElementGetLogicalMax(y) / 2);
  touch_updates = 0;
  report_updates = 0;
  DispatchTouches(device);
  Check(touch_updates == 1 && report_updates == 1,
    "one M14t contact dispatches one touch and one completed frame");
  Check(last_contact_id == 123 && last_on_surface &&
    fabs(last_position.x - 0.5) < 0.001 && fabs(last_position.y - 0.5) < 0.001,
    "M14t contact preserves identity, tip state, and normalized coordinates");
  DeallocateDeviceState((IOHIDDeviceRef)root);
}

static unsigned int ReadLittleEndian16(const UInt8 *bytes) {
  return (unsigned int)bytes[0] | ((unsigned int)bytes[1] << 8);
}

static void TestRecordedReports(IOHIDElementRef root, const char *directory) {
  char path[4096];
  snprintf(path, sizeof(path), "%s/m14t-touch-sequence.hex", directory);
  FILE *file = fopen(path, "r");
  if (!file) { perror(path); exit(2); }
  HIDDeviceState *device = AllocateDeviceState((IOHIDDeviceRef)root, 1);
  IdentifyElements(device, root, FALSE);
  IOHIDElementRef count = FindElement(root, kHIDPage_Digitizer, kHIDUsage_Dig_ContactCount);
  char line[256];
  int report_index = 0;
  while (fgets(line, sizeof(line), file)) {
    UInt8 bytes[40];
    for (size_t i = 0; i < sizeof(bytes); i++) {
      unsigned int byte;
      if (sscanf(line + i * 2, "%2x", &byte) != 1) abort();
      bytes[i] = (UInt8)byte;
    }
    // The captured descriptor defines a count byte, five seven-byte contact
    // slots (flags, 16-bit ID, 16-bit X, 16-bit Y), then a 16-bit scan time.
    if (bytes[0] != 0x0c) abort();
    StoreValue(device, count, bytes[2]);
    CFArrayRef children = FixtureGetChildren(root);
    size_t contact_index = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(children); i++) {
      IOHIDElementRef finger = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
      if (IOHIDElementGetType(finger) != kIOHIDElementTypeCollection) continue;
      const UInt8 *contact = bytes + 3 + 7 * contact_index++;
      StoreValue(device, FindElement(finger, kHIDPage_Digitizer, kHIDUsage_Dig_TipSwitch),
        contact[0] & 1);
      StoreValue(device, FindElement(finger, kHIDPage_Digitizer, kHIDUsage_Dig_TouchValid),
        (contact[0] >> 2) & 1);
      StoreValue(device, FindElement(finger, kHIDPage_Digitizer, kHIDUsage_Dig_ContactIdentifier),
        ReadLittleEndian16(contact + 1));
      StoreValue(device, FindElement(finger, kHIDPage_GenericDesktop, kHIDUsage_GD_X),
        ReadLittleEndian16(contact + 3));
      StoreValue(device, FindElement(finger, kHIDPage_GenericDesktop, kHIDUsage_GD_Y),
        ReadLittleEndian16(contact + 5));
    }
    touch_updates = 0;
    report_updates = 0;
    DispatchTouches(device);
    Boolean expected_on_surface = (bytes[3] & 1) != 0;
    CGFloat expected_x = (CGFloat)ReadLittleEndian16(bytes + 6) / 12372.0;
    CGFloat expected_y = (CGFloat)ReadLittleEndian16(bytes + 8) / 6960.0;
    char message[256];
    snprintf(message, sizeof(message), "captured M14t %s preserves ID, tip state, position, and frame",
      report_index == 0 ? "touch down" : report_index == 1 ? "movement" : "lift off");
    Check(touch_updates == 1 && report_updates == 1 && last_contact_id == 1 &&
      last_on_surface == expected_on_surface && fabs(last_position.x - expected_x) < 0.00001 &&
      fabs(last_position.y - expected_y) < 0.00001, message);
    report_index++;
  }
  fclose(file);
  Check(report_index == 3, "capture contains touch down, movement, and lift off");
  DeallocateDeviceState((IOHIDDeviceRef)root);
}

int main(int argc, char **argv) {
  setbuf(stdout, NULL);
  if (argc != 2) { fprintf(stderr, "usage: %s FIXTURE_DIRECTORY\n", argv[0]); return 2; }
  IOHIDElementRef primary = LoadFixture(argv[1], "0c");
  IOHIDElementRef secondary = LoadFixture(argv[1], "20");
  TestCollectionDiscovery(primary, 5, "0x0c");
  TestCollectionDiscovery(secondary, 1, "0x20");
  TestStoredValues(primary);
  TestTouchDispatch(primary);
  TestRecordedReports(primary, argv[1]);
  TestBatchedQueueReports(primary);
  TestHybridQueueReports(primary);
  TestUnrelatedApplications(primary);
  for (size_t i = 0; i < fixture_node_count; i++) {
    CFRelease(fixture_nodes[i].children);
    CFRelease(fixture_nodes[i].element);
    CFRelease(fixture_nodes[i].properties);
  }
  printf("%d regression failure(s)\n", failures);
  return failures ? 1 : 0;
}
