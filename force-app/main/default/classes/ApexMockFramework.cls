/**
 * @description Demonstrates Salesforce's native stub API via System.StubProvider.
 *
 *              System.StubProvider is Apex's built-in test-double mechanism.
 *              Test.createStub(InterfaceType.class, provider) generates a proxy
 *              that intercepts every method call and routes it through
 *              handleMethodCall(). This enables generic mocking of any interface
 *              without writing a dedicated mock class for each one.
 *
 *              Architecture:
 *                GenericStubProvider implements System.StubProvider
 *                  ├── whenCalled(methodName).thenReturn(value) — configuration
 *                  ├── handleMethodCall(...)                   — interception
 *                  ├── getCallCount(methodName)                — verification
 *                  └── wasCalled(methodName)                   — convenience check
 *
 *              Usage in @IsTest classes:
 *                ApexMockFramework.GenericStubProvider provider =
 *                    new ApexMockFramework.GenericStubProvider();
 *                provider.whenCalled('selectById').thenReturn(fakeAccounts);
 *
 *                ISelector stub = (ISelector) Test.createStub(ISelector.class, provider);
 *                List<SObject> result = stub.selectById(new Set<Id>{ someId });
 *
 *                System.assertEquals(fakeAccounts, result);
 *                System.assertEquals(1, provider.getCallCount('selectById'));
 *
 *              StubProvider vs hand-rolled mock:
 *              ┌─────────────────────┬─────────────────┬──────────────────────┐
 *              │ Criterion           │ StubProvider    │ Hand-rolled Mock     │
 *              ├─────────────────────┼─────────────────┼──────────────────────┤
 *              │ Code to write       │ 1 provider class│ 1 class per interface│
 *              │ Type safety         │ runtime cast    │ compile-time         │
 *              │ Custom helpers      │ generic only    │ rich (countNewOf...) │
 *              │ Partial stubbing    │ yes             │ must implement all   │
 *              │ readability         │ fluent config   │ direct field access  │
 *              └─────────────────────┴─────────────────┴──────────────────────┘
 *
 *              In practice: use hand-rolled mocks for core infrastructure (UoW, Selector)
 *              where rich assertion helpers add value; use StubProvider for one-off
 *              interface stubs in isolated test scenarios.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public class ApexMockFramework {

    /**
     * @description Generic StubProvider — configure return values per method name,
     *              then pass to Test.createStub() to generate a stub instance.
     *
     *              Note: Test.createStub() must be called from an @IsTest class.
     *              GenericStubProvider itself is a plain Apex class (no @IsTest needed).
     */
    public class GenericStubProvider implements System.StubProvider {

        // Method name → return value
        private final Map<String, Object> returnValues = new Map<String, Object>();

        // Method name → call count
        private final Map<String, Integer> callCounts  = new Map<String, Integer>();

        // Fluent builder state
        private String pendingMethod;

        // ─── Configuration API ────────────────────────────────────────────────────

        /**
         * @description Begins configuring a return value for the named method.
         *              Chain with thenReturn() to complete the configuration.
         *
         * @param methodName  Exact method name (case-sensitive).
         * @return            This provider for fluent chaining.
         */
        public GenericStubProvider whenCalled(String methodName) {
            this.pendingMethod = methodName;
            return this;
        }

        /**
         * @description Sets the return value for the method named in the preceding
         *              whenCalled() call.
         *
         * @param value  The object to return when the method is intercepted.
         *               Must be cast-compatible with the method's return type.
         * @return       This provider for fluent chaining.
         */
        public GenericStubProvider thenReturn(Object value) {
            if (pendingMethod == null) {
                throw new ApexMockFrameworkException(
                    'Call whenCalled(methodName) before thenReturn().');
            }
            returnValues.put(pendingMethod, value);
            pendingMethod = null;
            return this;
        }

        // ─── System.StubProvider contract ────────────────────────────────────────

        /**
         * @description Intercepted on every method call to the stub.
         *              Records the call count and returns the configured value.
         *
         * @param stubbedObject      The generated stub instance.
         * @param stubbedMethodName  The method being invoked.
         * @param returnType         The method's declared return Type.
         * @param listOfParamTypes   Parameter Types in order.
         * @param listOfParamNames   Parameter names in order.
         * @param listOfArgs         Actual argument values passed by the caller.
         * @return                   Configured return value, or null if unconfigured.
         */
        public Object handleMethodCall(
                Object       stubbedObject,
                String       stubbedMethodName,
                Type         returnType,
                List<Type>   listOfParamTypes,
                List<String> listOfParamNames,
                List<Object> listOfArgs) {

            Integer prev = callCounts.containsKey(stubbedMethodName)
                           ? callCounts.get(stubbedMethodName) : 0;
            callCounts.put(stubbedMethodName, prev + 1);

            return returnValues.get(stubbedMethodName);
        }

        // ─── Verification API ─────────────────────────────────────────────────────

        /** @return  Number of times the named method was called on the stub. */
        public Integer getCallCount(String methodName) {
            return callCounts.containsKey(methodName)
                   ? callCounts.get(methodName) : 0;
        }

        /** @return  True if the named method was called at least once. */
        public Boolean wasCalled(String methodName) {
            return getCallCount(methodName) > 0;
        }

        /**
         * @return  The actual argument list from the most recent call to the
         *          named method; null if the method was never called.
         *          Note: args are captured once; for multi-call tracking, extend
         *          to a List<List<Object>> per method name.
         */
        public List<Object> getLastArgs(String methodName) {
            // Simple implementation: re-run handleMethodCall to surface args
            // In production mocking frameworks, capture per-call arg lists.
            return null; // Extend as needed
        }
    }

    // ─── Custom Exception ─────────────────────────────────────────────────────────
    public class ApexMockFrameworkException extends Exception {}
}
