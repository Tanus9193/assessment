# Build Stage
FROM node:20-alpine AS build
WORKDIR /app
COPY react-app/  .
RUN npm install
RUN npm install @testing-library/react@latest
RUN npm install web-vitals
RUN npm run build

# Serve with NGINX
FROM nginx:alpine
COPY --from=build /app/build /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]

