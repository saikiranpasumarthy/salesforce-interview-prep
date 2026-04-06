/**
 * Application
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 22 — Application Factory: central registry for Selector, Domain,
 * Service, and Unit of Work instances. This is the Dependency Injection (DI)
 * container for the SoC architecture.
 *
 * FACTORY PATTERN:
 * ═════════════════
 * Instead of calling `new AccountSelector()` directly (which hardcodes the
 * dependency), callers ask the factory:
 *   Application.Selector.newInstance(IAccountSelector.class)
 *
 * In tests, you stub the factory to return a mock:
 *   Application.Selector.setMock(IAccountSelector.class, mockSelector);
 *
 * This makes every layer independently unit-testable:
 *   • Test the Domain with a mock Selector (no DB hits)
 *   • Test the Service with a mock Domain + mock UoW (no trigger firing)
 *   • Test the Selector directly with real DB (integration test)
 *
 * BINDING MAP:
 * ═════════════
 * The binding map maps Interface → ConcreteClass.
 * In production, this is the concrete implementation.
 * In tests, setMock() replaces the binding with a mock object.
 *
 * SFDX PROJECT NOTE:
 * ═══════════════════
 * This is a hand-rolled DI container following the fflib Application class
 * pattern. Full fflib provides fflib_Application with additional features
 * (lazy loading, multi-org, domain event publishing). This implementation
 * covers the core SoC benefits without the managed package dependency.
 */
public class Application {

    // ─────────────────────────────────────────────────────────────────────────
    // Selector factory
    // ─────────────────────────────────────────────────────────────────────────

    public static final SelectorFactory Selector = new SelectorFactory(
        new Map<Type, Type>{
            IAccountSelector.class => AccountSelector.class
        }
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Domain factory
    // ─────────────────────────────────────────────────────────────────────────

    public static final DomainFactory Domain = new DomainFactory(
        new Map<Schema.SObjectType, Type>{
            Account.SObjectType => AccountDomain.class
        }
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Unit of Work factory
    // ─────────────────────────────────────────────────────────────────────────

    // SObject types in INSERT order — parents before children
    public static final UnitOfWorkFactory UnitOfWork = new UnitOfWorkFactory(
        new List<Schema.SObjectType>{
            Account.SObjectType,
            Contact.SObjectType,
            Opportunity.SObjectType,
            Task.SObjectType,
            Project__c.SObjectType,
            Project_Task__c.SObjectType
        }
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Factory implementations
    // ─────────────────────────────────────────────────────────────────────────

    public class SelectorFactory {
        private final Map<Type, Type>   bindings;
        private final Map<Type, Object> mocks = new Map<Type, Object>();

        SelectorFactory(Map<Type, Type> bindings) {
            this.bindings = bindings;
        }

        /** Returns a new selector instance for the given interface. */
        public Object newInstance(Type selectorInterface) {
            if (mocks.containsKey(selectorInterface)) {
                return mocks.get(selectorInterface);
            }
            Type concreteType = bindings.get(selectorInterface);
            if (concreteType == null) {
                throw new ApplicationException(
                    'No selector binding found for: ' + selectorInterface.getName());
            }
            return concreteType.newInstance();
        }

        /** Replaces the binding with a mock for the current test. */
        @TestVisible
        public void setMock(Type selectorInterface, Object mock) {
            mocks.put(selectorInterface, mock);
        }
    }

    public class DomainFactory {
        private final Map<Schema.SObjectType, Type>   bindings;
        private final Map<Schema.SObjectType, Object> mocks =
            new Map<Schema.SObjectType, Object>();

        DomainFactory(Map<Schema.SObjectType, Type> bindings) {
            this.bindings = bindings;
        }

        /** Returns a new domain instance wrapping the provided records. */
        public Object newInstance(List<SObject> records) {
            if (records == null || records.isEmpty()) {
                throw new ApplicationException('Domain.newInstance() called with empty records');
            }
            Schema.SObjectType sType = records[0].getSObjectType();

            if (mocks.containsKey(sType)) { return mocks.get(sType); }

            Type concreteType = bindings.get(sType);
            if (concreteType == null) {
                throw new ApplicationException(
                    'No domain binding found for sObject: ' + sType.getDescribe().getName());
            }
            // Domain constructors accept List<SObject> — use Type.newInstance() + reflection
            // Since Apex doesn't support constructor parameters via Type.newInstance(),
            // we use a simple convention: Domain classes expose a static newInstance() factory
            return invokeConstructor(concreteType, records);
        }

        @TestVisible
        public void setMock(Schema.SObjectType sType, Object mock) {
            mocks.put(sType, mock);
        }

        private Object invokeConstructor(Type domainType, List<SObject> records) {
            // Apex reflection workaround: cast to IAccountDomain for Account
            // In a full fflib implementation, this uses fflib_SObjectDomain base class
            // For this portfolio, we instantiate directly since we know the types
            if (domainType == AccountDomain.class) {
                return new AccountDomain((List<Account>) records);
            }
            throw new ApplicationException(
                'Domain constructor not found for: ' + domainType.getName());
        }
    }

    public class UnitOfWorkFactory {
        private final List<Schema.SObjectType> sObjectTypes;
        private IUnitOfWork mockUow;

        UnitOfWorkFactory(List<Schema.SObjectType> sObjectTypes) {
            this.sObjectTypes = sObjectTypes;
        }

        /** Returns a new UnitOfWork instance with the registered sObject types. */
        public IUnitOfWork newInstance() {
            if (mockUow != null) { return mockUow; }
            return new UnitOfWork(sObjectTypes);
        }

        @TestVisible
        public void setMock(IUnitOfWork mock) {
            mockUow = mock;
        }
    }

    public class ApplicationException extends Exception {}
}
