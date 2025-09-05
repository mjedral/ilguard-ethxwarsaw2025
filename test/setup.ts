// Jest setup file for global test configuration
import * as dotenv from "dotenv";

// Load test environment variables
dotenv.config({ path: ".env.test" });

// Global test timeout
jest.setTimeout(30000);

// Mock console methods in tests to reduce noise
global.console = {
  ...console,
  // Uncomment to suppress console.log in tests
  // log: jest.fn(),
  // warn: jest.fn(),
  // error: jest.fn(),
};
