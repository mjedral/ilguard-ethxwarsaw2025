// Basic test to verify Jest setup
describe("Project Setup", () => {
    it("should have Jest configured correctly", () => {
        expect(true).toBe(true);
    });

    it("should be able to import TypeScript modules", () => {
        const testObject = { name: "IL Guard Mini", version: "1.0.0" };
        expect(testObject.name).toBe("IL Guard Mini");
    });
});